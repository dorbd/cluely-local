import Foundation
import Testing
@testable import CluelyLocalCore

/// Feeds `count` frames at `probability`, 32 ms apart, returning any clips and the next frame index.
private func feed(_ segmenter: inout Segmenter, _ probability: Double, frames count: Int, from start: Int = 0) -> ([Clip], Int) {
    var clips: [Clip] = []
    for index in start..<start + count {
        let frame = [Float](repeating: Float(index), count: segmenter.config.frameSamples)
        if let clip = segmenter.push(frame, probability: probability, time: Double(index + 1) * 0.032) { clips.append(clip) }
    }
    return (clips, start + count)
}

@Suite("VAD segmentation timing")
struct SegmenterTests {
    let config = VADConfig()

    @Test("Cluely's settings in frames: 300 ms pad, 300 ms redemption, 400 ms minimum, 20 s cap")
    func frameCounts() {
        #expect(config.frames(config.preSpeechPadMs) == 10)
        #expect(config.frames(config.redemptionMs) == 10)
        #expect(config.frames(config.minSpeechMs) == 13)
        #expect(config.frames(config.maxClipMs) == 625)
    }

    @Test("silence never makes a clip")
    func silence() {
        var segmenter = Segmenter()
        #expect(feed(&segmenter, 0, frames: 1_000).0.isEmpty)
        #expect(!segmenter.isSpeaking)
    }

    @Test("a clip closes 300 ms after the last speech frame, not before")
    func redemption() throws {
        var segmenter = Segmenter()
        var (clips, next) = feed(&segmenter, 0, frames: 30)
        (clips, next) = feed(&segmenter, 0.9, frames: 31, from: next)      // ~1 s of speech
        (clips, next) = feed(&segmenter, 0.1, frames: 9, from: next)       // one frame short
        #expect(clips.isEmpty)
        (clips, _) = feed(&segmenter, 0.1, frames: 1, from: next)
        let clip = try #require(clips.first)
        #expect(abs(clip.closedTime - clip.speechEndTime - 10 * 0.032) < 1e-9)
        #expect(clip.speechFrames == 31)
        #expect(!clip.capped)
    }

    @Test("keeps 300 ms of audio from before speech started")
    func preSpeechPad() throws {
        var segmenter = Segmenter()
        var (_, next) = feed(&segmenter, 0, frames: 40)
        var clips: [Clip]
        (_, next) = feed(&segmenter, 0.9, frames: 20, from: next)
        (clips, _) = feed(&segmenter, 0, frames: 10, from: next)
        let clip = try #require(clips.first)
        #expect(clip.samples.count == (10 + 20 + 10) * 512)
        #expect(clip.samples.first == 30)  // frames 30...39 were the pad
    }

    @Test("drops misfires under 400 ms of speech", arguments: [(12, false), (13, true)])
    func minimumSpeech(speechFrames: Int, kept: Bool) {
        var segmenter = Segmenter()
        var (_, next) = feed(&segmenter, 0.9, frames: speechFrames)
        var clips: [Clip]
        (clips, next) = feed(&segmenter, 0, frames: 44, from: next)
        #expect(clips.isEmpty == !kept)
    }

    @Test("probabilities between the thresholds neither end nor extend speech")
    func hysteresis() {
        var segmenter = Segmenter()
        var (_, next) = feed(&segmenter, 0.9, frames: 20)
        var clips: [Clip]
        (clips, next) = feed(&segmenter, 0.27, frames: 200, from: next)
        #expect(clips.isEmpty)
        #expect(segmenter.isSpeaking)
    }

    @Test("cuts at 20 s and keeps listening")
    func hardCap() {
        var segmenter = Segmenter()
        let (clips, _) = feed(&segmenter, 0.9, frames: 1_300)
        #expect(clips.count == 2)
        #expect(clips.allSatisfy { $0.capped && $0.samples.count == 625 * 512 })
        #expect(segmenter.isSpeaking)
    }

    @Test("flush returns the clip in progress")
    func flush() {
        var segmenter = Segmenter()
        _ = feed(&segmenter, 0.9, frames: 20)
        #expect(segmenter.flush(time: 1) != nil)
        #expect(segmenter.flush(time: 2) == nil)
    }
}

@Suite("Energy scorer")
struct EnergyScorerTests {
    @Test("digital silence scores 0, a loud tone scores 1")
    func extremes() {
        var scorer = EnergyScorer()
        #expect(scorer.probability([Float](repeating: 0, count: 512)) == 0)
        let tone = (0..<512).map { Float(sin(Double($0) * 0.2) * 0.3) }
        #expect(scorer.probability(tone) == 1)
    }

    @Test("a noisy room at launch is the noise floor straight away, not speech")
    func startsAtRoomLevel() {
        var scorer = EnergyScorer()
        let hum = (0..<512).map { Float(sin(Double($0) * 0.05) * 0.01) }  // about -43 dBFS
        let scores = (0..<50).map { _ in scorer.probability(hum) }
        #expect(scores.allSatisfy { $0 < 0.25 })
        let voice = (0..<512).map { Float(sin(Double($0) * 0.2) * 0.3) }  // about 29 dB louder
        #expect(scorer.probability(voice) >= 0.3)
    }

    @Test("a hum that starts later becomes the floor and stops counting as speech")
    func adaptsToHum() {
        var scorer = EnergyScorer()
        _ = scorer.probability([Float](repeating: 0.0001, count: 512))  // a quiet room first
        let hum = (0..<512).map { Float(sin(Double($0) * 0.05) * 0.01) }
        let first = scorer.probability(hum)
        var last = first
        for _ in 0..<5_000 { last = scorer.probability(hum) }
        #expect(first > 0.3)
        #expect(last < 0.25)
    }
}

@Suite("Me / Them labelling")
struct ConversationTests {
    let frame = [Float](repeating: 0, count: 512)

    private func push(_ conversation: inout Conversation, _ speaker: Speaker, _ probability: Double,
                      frames: Int, at start: inout Int) -> [SpeakerClip] {
        var out: [SpeakerClip] = []
        for _ in 0..<frames {
            start += 1
            out += conversation.push(speaker, frame: frame, probability: probability, time: Double(start) * 0.032)
        }
        return out
    }

    @Test("labels clips by source")
    func labels() {
        var conversation = Conversation()
        var t = 0
        var clips = push(&conversation, .them, 0.9, frames: 20, at: &t)
        clips += push(&conversation, .them, 0, frames: 44, at: &t)
        clips += push(&conversation, .me, 0.9, frames: 20, at: &t)
        clips += push(&conversation, .me, 0, frames: 44, at: &t)
        #expect(clips.map(\.speaker) == [.them, .me])
    }

    /// Them and Me frames arriving together, as they do live.
    private func both(_ conversation: inout Conversation, them: Double, me: Double, frames: Int, at t: inout Int) -> [SpeakerClip] {
        var out: [SpeakerClip] = []
        for _ in 0..<frames {
            t += 1
            out += conversation.push(.them, frame: frame, probability: them, time: Double(t) * 0.032)
            out += conversation.push(.me, frame: frame, probability: me, time: Double(t) * 0.032)
        }
        return out
    }

    @Test("drops the mic while Them is talking, so speaker echo isn't transcribed as Me")
    func echoGate() {
        var conversation = Conversation()
        var t = 0
        var clips = both(&conversation, them: 0.9, me: 0.9, frames: 100, at: &t)
        clips += both(&conversation, them: 0, me: 0, frames: 60, at: &t)
        #expect(clips.map(\.speaker) == [.them])
        #expect(conversation.droppedMicFrames == 100 + 9)  // plus the 300 ms echo tail
    }

    @Test("reopens the mic 300 ms after Them goes quiet, so a quick reply is kept")
    func quickReply() {
        var conversation = Conversation()
        var t = 0
        var clips = both(&conversation, them: 0.9, me: 0.9, frames: 30, at: &t)
        clips += both(&conversation, them: 0, me: 0, frames: 10, at: &t)    // 320 ms gap
        clips += both(&conversation, them: 0, me: 0.9, frames: 20, at: &t)  // Me answers
        clips += both(&conversation, them: 0, me: 0, frames: 60, at: &t)
        #expect(clips.map(\.speaker) == [.them, .me])
        #expect(conversation.isMicGated(at: Double(t) * 0.032) == false)
    }

    @Test("without the gate, the echo comes through as Me")
    func noGate() {
        var conversation = Conversation(echoGate: false)
        var t = 0
        var clips = both(&conversation, them: 0.9, me: 0.9, frames: 30, at: &t)
        clips += both(&conversation, them: 0, me: 0, frames: 60, at: &t)
        #expect(Set(clips.map(\.speaker)) == [.them, .me])
    }

    @Test("asking mid-question cuts Them's clip now, instead of waiting for the pause")
    func cutOnAsk() {
        var conversation = Conversation()
        var t = 0
        let before = push(&conversation, .them, 0.9, frames: 40, at: &t)  // still talking
        #expect(before.isEmpty)
        let cut = conversation.flush(time: Double(t) * 0.032)
        #expect(cut.map(\.speaker) == [.them])
        #expect(cut.first?.clip.capped == false)
    }

    @Test("Me mid-sentence when Them starts: the Me clip is closed and kept")
    func interruptedMe() {
        var conversation = Conversation()
        var t = 0
        _ = push(&conversation, .me, 0.9, frames: 30, at: &t)
        let clips = push(&conversation, .them, 0.9, frames: 1, at: &t)
        #expect(clips.map(\.speaker) == [.me])
    }
}

@Suite("Clip backlog")
struct BacklogTests {
    @Test("queue policy never drops, however far behind whisper is")
    func queue() {
        var backlog = Backlog(policy: .queue)
        let results = (0..<12).map { _ in backlog.offer() }
        #expect(results.allSatisfy { $0 })
        #expect(backlog.dropped == 0)
        #expect(backlog.peakInFlight == 12)
    }

    @Test("Cluely's policy drops the clip that arrives with 4 in flight")
    func dropAtFour() {
        var backlog = Backlog(policy: .drop(maxInFlight: 4))
        let results = (0..<6).map { _ in backlog.offer() }
        #expect(results == [true, true, true, true, false, false])
        backlog.finish()
        let afterOneFinished = backlog.offer()
        #expect(afterOneFinished)
        #expect(backlog.dropped == 2)
    }
}

@Suite("Transcript")
struct TranscriptTests {
    let utc = TimeZone(identifier: "UTC")!
    let start = Date(timeIntervalSince1970: 1_792_278_000) // 2026-10-17 23:00:00 UTC

    @Test("formats a line")
    func format() {
        let line = TranscriptLine(date: start.addingTimeInterval(65), speaker: .them, text: "Can you hear me?")
        #expect(line.formatted(timeZone: utc) == "- [23:01:05] Them: Can you hear me?")
        #expect(Transcript.header(start, timeZone: utc) == "# Call, 2026-10-17 23:00")
    }

    @Test("parses what it writes, across midnight")
    func roundTrip() {
        let lines = [
            TranscriptLine(date: start.addingTimeInterval(10), speaker: .me, text: "Hi: it's me"),
            TranscriptLine(date: start.addingTimeInterval(3_700), speaker: .them, text: "Past midnight now."),
        ]
        let markdown = ([Transcript.header(start, timeZone: utc), "", "not a line"] + lines.map { $0.formatted(timeZone: utc) })
            .joined(separator: "\n")
        #expect(Transcript.parse(markdown, timeZone: utc) == lines)
    }

    @Test("keeps only the last 5 minutes")
    func recentWindow() {
        let lines = [400, 299, 10].map { TranscriptLine(date: start.addingTimeInterval(-Double($0)), speaker: .me, text: "x") }
        #expect(Transcript.recent(lines, now: start).count == 2)
    }

    @Test("puts lines back in spoken order: a short reply can be transcribed before a longer line said first")
    func spokenOrder() {
        let long = TranscriptLine(date: start.addingTimeInterval(-20), speaker: .them, text: "A long question")
        let reply = TranscriptLine(date: start.addingTimeInterval(-5), speaker: .me, text: "Yes")
        #expect(Transcript.recent([reply, long], now: start) == [long, reply])
    }

    @Test("strips whisper's silence markers")
    func clean() {
        #expect(Transcript.clean(" [BLANK_AUDIO]\n") == "")
        #expect(Transcript.clean(" Hello there.\n And again.\n") == "Hello there. And again.")
        #expect(Transcript.clean(" -\n") == "")
        #expect(Transcript.clean(" - Not for enterprise.") == "Not for enterprise.")
    }
}

@Suite("Ask prompt")
struct PromptTests {
    let utc = TimeZone(identifier: "UTC")!

    @Test("screen, then transcript, then the question")
    func order() throws {
        let line = TranscriptLine(date: Date(timeIntervalSince1970: 0), speaker: .them, text: "What's your price?")
        let prompt = AskPrompt.build(question: "How do I answer?", transcript: [line], screen: .file("/tmp/s.png"), timeZone: utc)
        let screen = try #require(prompt.range(of: "<screen_use>"))
        let audio = try #require(prompt.range(of: "<audio_transcript>"))
        let question = try #require(prompt.range(of: "How do I answer?"))
        #expect(screen.lowerBound < audio.lowerBound && audio.lowerBound < question.lowerBound)
        #expect(prompt.contains("/tmp/s.png"))
        #expect(prompt.contains("- [00:00:00] Them: What's your price?"))
        #expect(prompt.hasSuffix("How do I answer?"))
    }

    @Test("tells the model to answer Them's latest question, even if it's cut off")
    func findsTheQuestion() {
        let prompt = AskPrompt.build(question: "", transcript: [], screen: .none)
        #expect(prompt.contains("If Them's latest lines ask me something"))
        #expect(prompt.contains("stops mid-sentence"))
        #expect(prompt.contains("Never state a price, feature, date or promise"))
    }

    @Test("each mode adds its own instructions", arguments: Mode.allCases)
    func modes(mode: Mode) {
        let prompt = AskPrompt.build(question: "q", transcript: [], screen: .none, mode: mode)
        #expect(prompt.contains(mode.instructions))
        #expect(prompt.contains("complexity") == (mode == .coding))
    }

    @Test("falls back to the default question and says when nothing was heard")
    func defaults() {
        let prompt = AskPrompt.build(question: "  ", transcript: [], screen: .none)
        #expect(prompt.hasSuffix(AskPrompt.defaultQuestion))
        #expect(prompt.contains("nothing transcribed"))
        #expect(prompt.contains("No screenshot"))
    }
}

@Suite("Audio formats")
struct WAVTests {
    @Test("writes a 44-byte header and 2 bytes a sample")
    func header() {
        let data = WAV.encode([0, 0.5, -0.5])
        #expect(data.count == 44 + 6)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
    }

    @Test("PCM bytes round-trip to floats")
    func roundTrip() {
        let samples: [Float] = [0, 0.25, -0.5]
        let decoded = WAV.floats(fromPCM16: WAV.encode(samples).dropFirst(44))
        #expect(zip(samples, decoded).allSatisfy { abs($0 - $1) < 0.001 })
    }
}

@Suite("Options")
struct OptionsTests {
    @Test("listens by default and queues clips")
    func defaults() throws {
        let options = try Options.parse([])
        #expect(options.command == .listen)
        #expect(options.policy == .queue)
        #expect(options.mic && options.echoGate && options.screen)
    }

    @Test("parses ask with and without a question")
    func ask() throws {
        #expect(try Options.parse(["ask", "what's their budget?"]).command == .ask(question: "what's their budget?"))
        #expect(try Options.parse(["ask", "--no-window"]).command == .ask(question: ""))
    }

    @Test("the question can be unquoted and come after flags")
    func unquotedQuestion() throws {
        let options = try Options.parse(["ask", "--no-window", "--mode", "coding", "what", "is", "the", "runtime?"])
        #expect(options.command == .ask(question: "what is the runtime?"))
        #expect(!options.window && options.mode == .coding)
        #expect(try !Options.parse(["ask", "--no-screen", "what", "now?"]).screen)
        #expect(try !Options.parse(["--no-screen"]).screen)
        #expect(try Options.parse(["ask", "--", "-1", "or", "0?"]).command == .ask(question: "-1 or 0?"))
    }

    @Test("parses modes and rejects unknown ones")
    func modes() throws {
        #expect(try Options.parse([]).mode == .general)
        #expect(try Options.parse(["--mode", "sales"]).mode == .sales)
        #expect(throws: Options.ParseError.badValue("--mode", "stealth")) { try Options.parse(["--mode", "stealth"]) }
        #expect(throws: Options.ParseError.unknownFlag("stray")) { try Options.parse(["stray"]) }
    }

    @Test("parses listen flags")
    func flags() throws {
        let options = try Options.parse(["--them-pid", "123", "--drop-at", "4", "--no-mic", "--seconds", "30"])
        #expect(options.themPID == 123 && options.policy == .drop(maxInFlight: 4) && !options.mic && options.seconds == 30)
    }

    @Test("rejects bad input")
    func errors() {
        #expect(throws: Options.ParseError.missingValue("--lang")) { try Options.parse(["--lang"]) }
        #expect(throws: Options.ParseError.badValue("--drop-at", "zero")) { try Options.parse(["--drop-at", "zero"]) }
        #expect(throws: Options.ParseError.unknownFlag("--stealth")) { try Options.parse(["--stealth"]) }
    }
}

@Suite("Timing log")
struct TimingLogTests {
    @Test("rows have as many columns as the header")
    func columns() {
        var record = TimingRecord(date: Date(), kind: .clip, note: "live, cold")
        record.speaker = .them
        record.lagMs = 2_300
        #expect(record.csvRow.split(separator: ",", omittingEmptySubsequences: false).count
                == TimingRecord.csvHeader.split(separator: ",").count)
        #expect(record.csvRow.contains(",Them,"))
    }
}

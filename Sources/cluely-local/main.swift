import AppKit
import CluelyLocalCore

// cluely-local: transcribe the call (Me = mic, Them = system audio), ask Claude about it with ⌘⏎.

let panelSeconds: TimeInterval = 60
/// How long ⌘⏎ waits for the words still being spoken to reach the transcript before asking anyway.
let cutWaitSeconds: TimeInterval = 4
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let model = root.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin")
let audiotee = root.appendingPathComponent("bin/audiotee")
let transcriptURL = root.appendingPathComponent("transcript.md")
let timingLog = TimingLog(url: root.appendingPathComponent("runs.csv"))

// A child that exits early (say `claude` isn't installed) closes its stdin. Writing to it must be an
// error the caller can report, not a signal that kills the app mid-call.
signal(SIGPIPE, SIG_IGN)

let options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    log("\(error)\n\n\(Options.usage)")
    exit(2)
}
if options.showHelp {
    print(Options.usage)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let panel = options.window ? AnswerPanel() : nil
var hotkey: Hotkey? // kept for the life of the app
var interrupt: DispatchSourceSignal? // likewise: a released source is cancelled and Ctrl+C would do nothing
var isAsking = false // main thread only: one ask at a time, so an older answer can't overwrite a newer one

/// Runs one ask off the main thread, prints the answer, shows it, logs the timing.
/// `before` runs first on the background queue (the cut). `finished` gets whether it worked, on main.
func ask(_ question: String, before: @escaping () -> Void = {}, then finished: @escaping (Bool) -> Void = { _ in }) {
    guard !isAsking else { return log("still answering the last question") }
    isAsking = true
    let started = Date()
    panel?.show("Listening for the end of the question…")
    DispatchQueue.global().async {
        before()
        if panel != nil {
            DispatchQueue.main.sync { panel?.hide() } // out of the screenshot
            Thread.sleep(forTimeInterval: 0.1)          // let the window server catch up
        }
        do {
            let answer = try Asker.ask(question, mode: options.mode, screen: options.screen, transcriptURL: transcriptURL) {
                DispatchQueue.main.async { panel?.show("Thinking…") }
            }
            let total = milliseconds(since: started)
            print("\n\(answer.text)\n")
            fflush(stdout)
            log(String(format: "answered in %.2fs (screenshot %dms, claude %dms), %@ in / %@ out tokens, %@",
                       Double(total) / 1000, answer.screenshotMs, answer.llmMs,
                       answer.inputTokens.map(String.init) ?? "?", answer.outputTokens.map(String.init) ?? "?",
                       answer.costUSD.map { String(format: "$%.4f", $0) } ?? "cost unknown"))
            try? timingLog.append(Asker.record(answer, totalMs: total))
            DispatchQueue.main.async {
                isAsking = false
                panel?.show(answer.text, hideAfter: panelSeconds)
                finished(true)
            }
        } catch {
            log("ask failed: \(error)")
            DispatchQueue.main.async {
                isAsking = false
                panel?.show("Couldn't get an answer: \(error)", hideAfter: panelSeconds)
                finished(false)
            }
        }
    }
}

/// Missing tools are reported up front, not discovered mid-call.
func checkInstalled(_ commands: [String]) {
    let missing = commands.filter { !isInstalled($0) }
    guard missing.isEmpty else {
        log("not installed: \(missing.joined(separator: ", ")). Run ./scripts/setup.sh from the repo root first.")
        exit(1)
    }
}

switch options.command {
case .ask(let question):
    if Asker.apiKey == nil, !isInstalled("claude") {
        log("claude isn't installed. Install Claude Code (https://claude.com/claude-code) or set ANTHROPIC_API_KEY.")
        exit(1)
    }
    ask(question, then: { worked in
        let code: Int32 = worked ? 0 : 1
        guard let panel else { exit(code) }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel.window,
                                               queue: .main) { _ in exit(code) }
        DispatchQueue.main.asyncAfter(deadline: .now() + panelSeconds) { exit(code) }
    })

case .listen:
    guard FileManager.default.fileExists(atPath: model.path) else {
        log("model missing at \(model.path). Run ./scripts/setup.sh from the repo root first.")
        exit(1)
    }
    checkInstalled(["whisper-cli", "ffmpeg"])
    let listener = Listener(options: options, model: model, audiotee: audiotee,
                            transcriptURL: transcriptURL, timingLog: timingLog)
    var quitting = false // main thread only
    let quit = { (code: Int32) in
        guard !quitting else { return }
        quitting = true
        listener.stop { summary in
            log(summary)
            exit(code)
        }
    }

    if let file = options.file {
        DispatchQueue.global().async {
            do { try listener.transcribeFile(file) } catch { log("could not read \(file): \(error)"); exit(1) }
            DispatchQueue.main.async { quit(0) }
        }
    } else {
        guard FileManager.default.isExecutableFile(atPath: audiotee.path) else {
            log("audiotee missing at \(audiotee.path). Run ./scripts/setup.sh from the repo root first.")
            exit(1)
        }
        if Asker.apiKey == nil, !isInstalled("claude") {
            log("claude isn't installed, so ⌘⏎ won't answer. Install Claude Code or set ANTHROPIC_API_KEY.")
        }
        // Ignored before audiotee and ffmpeg start, so they inherit it: Ctrl+C in the terminal reaches the
        // whole process group, and the app should stop them itself, after the last clips are transcribed.
        signal(SIGINT, SIG_IGN)
        do {
            try listener.start { speaker, status in
                DispatchQueue.main.async {
                    guard !quitting else { return }
                    // Keeping on would leave you thinking you're being transcribed when you aren't.
                    log("\(speaker.rawValue) audio stopped (status \(status)): check the microphone and System Audio " +
                        "Recording permissions. Stopping.")
                    quit(1)
                }
            }
        } catch {
            log("could not start audio: \(error)")
            exit(1)
        }

        hotkey = Hotkey {
            ask(AskPrompt.defaultQuestion, before: {
                // Like Cluely: end the clip being spoken and wait for it to be transcribed, so the
                // question they're still asking is in the prompt.
                let cut = DispatchSemaphore(value: 0)
                listener.cut { cut.signal() }
                if cut.wait(timeout: .now() + cutWaitSeconds) == .timedOut {
                    log("whisper is behind, asking without the last few seconds")
                }
            })
        }
        if hotkey == nil { log("⌘⏎ is taken by another app; use `cluely-local ask` instead") }
        log("listening: Them = system audio\(options.mic ? ", Me = microphone" : ""), \(options.mode.rawValue) mode. " +
            "⌘⏎ to ask, Ctrl+C to stop.")

        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        // A second Ctrl+C quits at once, without waiting for whisper to finish the queue.
        source.setEventHandler {
            if quitting { exit(130) }
            quit(0)
        }
        source.resume()
        interrupt = source
        if let seconds = options.seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { quit(0) }
        }
    }
}

app.run()

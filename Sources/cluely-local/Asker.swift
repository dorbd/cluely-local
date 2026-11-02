import Foundation
import CluelyLocalCore

/// Screenshot + last 5 minutes of transcript + question → Claude Haiku.
/// Uses the Claude Code CLI (your existing plan), or the API when ANTHROPIC_API_KEY is set.
enum Asker {
    static let timeout: TimeInterval = 60
    static let screenshotMaxPixels = 1_600  // larger images cost tokens without helping
    static let apiModel = ProcessInfo.processInfo.environment["CLUELY_API_MODEL"] ?? "claude-haiku-4-5"
    static let apiMaxTokens = 1_200  // room for code in coding mode
    /// Set and non-empty: answers come from the API instead of the Claude Code CLI.
    static let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }

    struct Answer {
        var text = ""
        var screenshotMs = 0
        var llmMs = 0
        var inputTokens: Int?
        var outputTokens: Int?
        var costUSD: Double?
    }

    /// `screenshotTaken` runs once the screen is captured, so a "Thinking…" panel stays out of the shot.
    /// With `screen` false, no screenshot is taken, so only the transcript leaves the Mac.
    static func ask(_ question: String, mode: Mode, screen: Bool = true, transcriptURL: URL,
                    screenshotTaken: () -> Void = {}) throws -> Answer {
        var answer = Answer()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cluely-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let shot = dir.appendingPathComponent("screen.png")
        let shotStarted = Date()
        let hasShot = screen && (try? run(["screencapture", "-x", shot.path], timeout: 10)) != nil
            && FileManager.default.fileExists(atPath: shot.path)
        if hasShot {
            _ = try? run(["sips", "-Z", String(screenshotMaxPixels), shot.path], timeout: 10)
        } else if screen {
            log("no screenshot: allow Screen Recording for your terminal app in System Settings")
        }
        answer.screenshotMs = milliseconds(since: shotStarted)
        screenshotTaken()

        let markdown = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
        let recent = Transcript.recent(Transcript.parse(markdown), now: Date(), window: AskPrompt.transcriptWindow)

        let llmStarted = Date()
        let prompt = AskPrompt.build(question: question, transcript: recent, screen: hasShot ? .attached : .none, mode: mode)
        let content = messageContent(prompt, image: hasShot ? shot : nil)
        if let key = apiKey {
            try askAPI(content, key: key, into: &answer)
        } else {
            try askCLI(content, cwd: dir, into: &answer)
        }
        answer.llmMs = milliseconds(since: llmStarted)
        return answer
    }

    /// The screenshot (if any) and the prompt, as Messages API content blocks. Both paths send the image
    /// inline, so the model never needs a tool to see it.
    private static func messageContent(_ prompt: String, image: URL?) -> [[String: Any]] {
        var content: [[String: Any]] = []
        if let image, let data = try? Data(contentsOf: image) {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png",
                                                        "data": data.base64EncodedString()]])
        }
        content.append(["type": "text", "text": prompt])
        return content
    }

    /// `claude -p` with no tools. The transcript and the screen come from other people, and a Read tool
    /// scoped with --allowedTools is still widened by allow rules or a permissive defaultMode in the
    /// user's own settings, so the image goes inline as stream-json instead. MCP servers are skipped, and
    /// the session isn't saved to Claude Code's history, so the transcript only lives in transcript.md.
    private static func askCLI(_ content: [[String: Any]], cwd: URL, into answer: inout Answer) throws {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        let input = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self) + "\n"
        // stream-json input requires stream-json output (and --verbose): one event per line, the answer
        // and its cost in the last one, of type "result".
        let output = try run(["claude", "-p", "--model", "haiku", "--strict-mcp-config", "--no-session-persistence",
                              "--tools", "", "--input-format", "stream-json", "--output-format", "stream-json",
                              "--verbose"],
                             stdin: input, cwd: cwd, timeout: timeout)
        let events = output.split(whereSeparator: \.isNewline).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        guard let json = events.last(where: { $0["type"] as? String == "result" }) else {
            throw AppError.process("claude returned no result")
        }
        if json["is_error"] as? Bool == true {
            throw AppError.process("claude: \(json["result"] as? String ?? "unknown error")")
        }
        answer.text = (json["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        answer.costUSD = json["total_cost_usd"] as? Double
        if let usage = json["usage"] as? [String: Any] {
            answer.inputTokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .compactMap { usage[$0] as? Int }.reduce(0, +)
            answer.outputTokens = usage["output_tokens"] as? Int
        }
    }

    /// Messages API, image inline. Cost isn't computed here; tokens are logged.
    private static func askAPI(_ content: [[String: Any]], key: String, into answer: inout Answer) throws {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": apiModel, "max_tokens": apiMaxTokens, "messages": [["role": "user", "content": content]],
        ])

        // timeoutInterval is an idle timeout, not a deadline, so the wait below is what bounds the call.
        // On timeout the task is cancelled and `result` is never read: the callback may still be writing it.
        let done = DispatchSemaphore(value: 0)
        var result: Result<(Data, Int), Error> = .failure(AppError.process("empty API response"))
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result = data.map { .success(($0, status)) } ?? .failure(error ?? AppError.process("empty API response"))
            done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw AppError.process("API call timed out after \(Int(timeout))s")
        }

        let (data, status) = try result.get()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let error = json?["error"] as? [String: Any] {
            throw AppError.process("API: \(error["message"] as? String ?? "unknown error")")
        }
        guard (200..<300).contains(status), let json else {
            throw AppError.process("API returned HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        answer.text = blocks.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let usage = json["usage"] as? [String: Any]
        answer.inputTokens = usage?["input_tokens"] as? Int
        answer.outputTokens = usage?["output_tokens"] as? Int
    }

    static func record(_ answer: Answer, totalMs: Int) -> TimingRecord {
        var record = TimingRecord(date: Date(), kind: .ask,
                                  note: apiKey == nil ? "cli" : "api")
        record.screenshotMs = answer.screenshotMs
        record.llmMs = answer.llmMs
        record.totalMs = totalMs
        record.inputTokens = answer.inputTokens
        record.outputTokens = answer.outputTokens
        record.costUSD = answer.costUSD
        return record
    }
}

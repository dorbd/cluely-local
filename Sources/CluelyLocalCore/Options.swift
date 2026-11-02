import Foundation

/// Command-line options.
public struct Options: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        case listen
        case ask(question: String)
    }

    public var command: Command = .listen
    public var language = "en"
    public var mic = true
    public var micDevice = "default"
    public var muteThem = false
    public var echoGate = true
    public var themPID: Int32?
    public var dropAt: Int?
    public var seconds: Double?
    public var file: String?
    public var window = true
    public var screen = true
    public var mode = Mode.general
    public var showHelp = false

    public init() {}

    public var policy: OverloadPolicy { dropAt.map { .drop(maxInFlight: $0) } ?? .queue }

    public static let usage = """
    cluely-local: a local meeting copilot. Transcribes your call into transcript.md and answers questions about it.

    Usage:
      cluely-local [options]             Listen: mic is "Me", whatever your Mac plays is "Them"
      cluely-local ask [question]        Screenshot + last 5 minutes + question to Claude

    While listening, press ⌘⏎ (Command-Return) for help with whatever is happening, usually the
    question they just asked. The clip in progress is cut and transcribed first.

    Both:
      --mode <name>     general, sales, interview or coding (default: general)
      --no-screen       Ask with the transcript only: no screenshot is taken or sent
    Listen options:
      --lang <code>     Spoken language, e.g. en, es, auto (default: en)
      --no-mic          Only transcribe Them
      --mic-device <n>  Microphone by name, e.g. "MacBook Pro Microphone" (default: the system input)
      --them-pid <pid>  Only capture this process's audio as Them (default: every app)
      --no-echo-gate    Keep the mic open while Them is talking (use with headphones)
      --drop-at <n>     Drop clips when n are already in flight, like Cluely (default: queue them all)
      --seconds <n>     Stop after n seconds
      --file <path>     Transcribe an audio file as Them, as fast as possible, instead of listening
      --mute-them       For testing: silence the captured audio while recording it
    Ask options:
      --no-window       Print the answer only
      -h, --help        Show this help
    """

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingValue(String)
        case badValue(String, String)
        case unknownFlag(String)

        public var description: String {
            switch self {
            case .missingValue(let flag): return "\(flag) needs a value"
            case .badValue(let flag, let value): return "\(flag) can't be \(value)"
            case .unknownFlag(let flag): return "unknown option \(flag)"
            }
        }
    }

    /// Parses arguments, excluding the program name.
    public static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var remaining = arguments[...]
        var question: [String]?
        if remaining.first == "ask" {
            remaining = remaining.dropFirst()
            question = []
        } else if remaining.first == "listen" {
            remaining = remaining.dropFirst()
        }

        func value(_ flag: String) throws -> String {
            guard let next = remaining.popFirst(), !next.hasPrefix("-") else { throw ParseError.missingValue(flag) }
            return next
        }
        func number<T: LosslessStringConvertible & Comparable & Numeric>(_ flag: String, _: T.Type) throws -> T {
            let raw = try value(flag)
            guard let parsed = T(raw), parsed > 0 else { throw ParseError.badValue(flag, raw) }
            return parsed
        }

        while let arg = remaining.popFirst() {
            switch arg {
            case "--lang": options.language = try value(arg)
            case "--no-mic": options.mic = false
            case "--mic-device": options.micDevice = try value(arg)
            case "--mute-them": options.muteThem = true
            case "--no-echo-gate": options.echoGate = false
            case "--them-pid": options.themPID = try number(arg, Int32.self)
            case "--drop-at": options.dropAt = try number(arg, Int.self)
            case "--seconds": options.seconds = try number(arg, Double.self)
            case "--file": options.file = try value(arg)
            case "--no-window": options.window = false
            case "--no-screen": options.screen = false
            case "--mode":
                let raw = try value(arg)
                guard let mode = Mode(rawValue: raw) else { throw ParseError.badValue(arg, raw) }
                options.mode = mode
            case "-h", "--help": options.showHelp = true
            case "--": question?.append(contentsOf: remaining); remaining = []
            default:
                // After `ask`, anything that isn't a flag is part of the question, so it needn't be quoted.
                guard question != nil, !arg.hasPrefix("-") else { throw ParseError.unknownFlag(arg) }
                question?.append(arg)
            }
        }
        if let question { options.command = .ask(question: question.joined(separator: " ")) }
        return options
    }
}

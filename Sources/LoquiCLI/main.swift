import Foundation
import LoquiClient

struct CLI {
    var command: Command = .say
    var text = ""
    var voice: String?
    var sessionId: String?
    var socketPath = LoquiSocketPaths.socketPath
    var quiet = false
    var showHelp = false
}

enum Command {
    case say
    case raw
    case generate
    case stop
    case status
    case voices
}

func printUsage() {
    let usage = """
    loqui - command line control for Loqui text-to-speech

    USAGE:
        loqui say [OPTIONS] <TEXT>
        echo "text" | loqui say [OPTIONS]
        loqui raw [OPTIONS] <TEXT> > audio.pcm
        loqui generate [OPTIONS] <TEXT> > audio.wav
        loqui stop
        loqui status
        loqui voices

    OPTIONS:
        -v, --voice <VOICE>   Voice to use (default: auto-assigned by Loqui)
        -S, --session-id <ID> Session identifier attached to queued speech
        --socket <PATH>       Loqui socket path
        -q, --quiet           Suppress status messages
        -h, --help            Show this help message

    SOCKET:
        \(LoquiSocketPaths.socketPath)

    EXAMPLES:
        loqui say "Hello, world!"
        loqui say -v alba "Good morning"
        echo "Long text from file" | loqui say
        loqui raw "Hello" | ffplay -f s16le -ar 24000 -ch_layout mono -nodisp -autoexit -i pipe:0
        loqui stop

    """
    FileHandle.standardError.write(Data(usage.utf8))
}

func parseArgs() -> CLI {
    var cli = CLI()
    var args = Array(CommandLine.arguments.dropFirst())
    if let first = args.first, !first.hasPrefix("-") {
        switch first {
        case "say", "speak":
            cli.command = .say
            args.removeFirst()
        case "raw":
            cli.command = .raw
            args.removeFirst()
        case "generate", "wav":
            cli.command = .generate
            args.removeFirst()
        case "stop":
            cli.command = .stop
            args.removeFirst()
        case "status", "health":
            cli.command = .status
            args.removeFirst()
        case "voices", "list-voices":
            cli.command = .voices
            args.removeFirst()
        default:
            cli.command = .say
        }
    }

    var positionalArgs: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]

        switch arg {
        case "-h", "--help":
            cli.showHelp = true
            return cli
        case "-l", "--list-voices":
            cli.command = .voices
            return cli
        case "-s", "--stop":
            cli.command = .stop
            return cli
        case "-r", "--raw":
            cli.command = .raw
        case "-v", "--voice":
            i += 1
            if i < args.count {
                cli.voice = args[i]
            }
        case "-S", "--session-id":
            i += 1
            if i < args.count {
                cli.sessionId = args[i]
            }
        case "--socket":
            i += 1
            if i < args.count {
                cli.socketPath = NSString(string: args[i]).expandingTildeInPath
            }
        case "-q", "--quiet":
            cli.quiet = true
        default:
            if arg.hasPrefix("-") {
                FileHandle.standardError.write(Data("Unknown option: \(arg)\n".utf8))
            } else {
                positionalArgs.append(arg)
            }
        }
        i += 1
    }

    cli.text = positionalArgs.joined(separator: " ")
    return cli
}

func readText(_ cli: CLI) -> String {
    if !cli.text.isEmpty {
        return cli.text
    }

    guard isatty(STDIN_FILENO) == 0,
          let stdinData = try? FileHandle.standardInput.readToEnd(),
          let stdinText = String(data: stdinData, encoding: .utf8)
    else {
        return ""
    }

    return stdinText.trimmingCharacters(in: .whitespacesAndNewlines)
}

func main() async {
    let cli = parseArgs()

    if cli.showHelp {
        printUsage()
        exit(0)
    }

    let client = TTSClient(socketPath: cli.socketPath)

    do {
        switch cli.command {
        case .voices:
            let response = try await client.send(.init(type: "voices"))
            let voices = response.voices ?? TTSClient.availableVoices
            print("Available voices:")
            for voice in voices {
                print("  \(voice)")
            }

        case .status:
            let response = try await client.send(.init(type: "health"))
            print("Loqui: \(response.ok ? "running" : "not running")")
            if let pending = response.pending {
                print("Pending: \(pending)")
            }
            if let playing = response.playing {
                print("Playing: \(playing)")
            }
            if let currentQueue = response.currentQueue {
                print("Current queue: \(currentQueue)")
            }

        case .stop:
            try await client.stop()
            if !cli.quiet {
                FileHandle.standardError.write(Data("Speech stopped.\n".utf8))
            }

        case .raw:
            let text = readText(cli)
            guard !text.isEmpty else {
                throw TTSError.serverError("No text provided. Use loqui --help for usage.")
            }
            let voice = cli.voice ?? "fantine"
            let data = try await client.synthesize(text: text, voice: voice)
            FileHandle.standardOutput.write(data)

        case .generate:
            let text = readText(cli)
            guard !text.isEmpty else {
                throw TTSError.serverError("No text provided. Use loqui --help for usage.")
            }
            let voice = cli.voice ?? "fantine"
            let data = try await client.generate(text: text, voice: voice)
            FileHandle.standardOutput.write(data)

        case .say:
            let text = readText(cli)
            guard !text.isEmpty else {
                throw TTSError.serverError("No text provided. Use loqui --help for usage.")
            }

            if let voice = cli.voice, !TTSClient.availableVoices.contains(voice) {
                FileHandle.standardError.write(Data("Warning: Unknown voice '\(voice)'\n".utf8))
            }

            let response = try await client.send(
                .init(
                    type: "speak",
                    text: text,
                    voice: cli.voice,
                    sourceApp: "loqui",
                    sessionId: cli.sessionId,
                    pid: Int(getpid())
                )
            )
            guard response.ok else {
                throw TTSError.serverError(response.error ?? "Broker enqueue failed")
            }

            if !cli.quiet {
                if let queued = response.queued {
                    FileHandle.standardError.write(Data("Enqueued speech job (queue size: \(queued)).\n".utf8))
                } else {
                    FileHandle.standardError.write(Data("Enqueued speech job.\n".utf8))
                }
            }
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    await main()
    semaphore.signal()
}
semaphore.wait()

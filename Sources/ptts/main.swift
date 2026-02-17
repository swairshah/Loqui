import Foundation
import LoquiClient

/// ptts - Loqui command line interface
/// 
/// Usage:
///   ptts "Hello world"                    # Speak text
///   ptts --voice alba "Hello"             # Use specific voice
///   echo "Hello" | ptts                   # Read from stdin
///   ptts --raw "Hello" > audio.pcm        # Output raw PCM
///   ptts --list-voices                    # List available voices
///   ptts --stop                           # Stop current speech

struct CLI {
    var text: String = ""
    var voice: String? = nil  // nil = use server default
    var port: Int = 18080
    var host: String = "127.0.0.1"
    var rawOutput: Bool = false
    var listVoices: Bool = false
    var stopSpeech: Bool = false
    var showHelp: Bool = false
    var quiet: Bool = false
}

func printUsage() {
    let usage = """
    ptts - Loqui command line text-to-speech
    
    USAGE:
        ptts [OPTIONS] <TEXT>
        echo "text" | ptts [OPTIONS]
    
    ARGUMENTS:
        <TEXT>    Text to speak (can also be piped via stdin)
    
    OPTIONS:
        -v, --voice <VOICE>   Voice to use (default: fantine)
        -p, --port <PORT>     Server port (default: 18080)
        -H, --host <HOST>     Server host (default: 127.0.0.1)
        -r, --raw             Output raw PCM audio (s16le, 24kHz, mono) to stdout
        -q, --quiet           Suppress status messages
        -l, --list-voices     List available voices
        -s, --stop            Stop current speech
        -h, --help            Show this help message
    
    EXAMPLES:
        ptts "Hello, world!"
        ptts -v alba "Good morning"
        echo "Long text from file" | ptts
        ptts --raw "Hello" > audio.pcm
        ptts --raw "Hello" | ffplay -f s16le -ar 24000 -ch_layout mono -nodisp -autoexit -i pipe:0
    
    VOICES:
        alba, marius, javert, fantine, cosette, eponine, azelma
    
    NOTE:
        Requires Loqui.app to be running (provides the TTS server).
    """
    FileHandle.standardError.write(usage.data(using: .utf8)!)
}

func parseArgs() -> CLI {
    var cli = CLI()
    let args = Array(CommandLine.arguments.dropFirst())
    var positionalArgs: [String] = []
    
    var i = 0
    while i < args.count {
        let arg = args[i]
        
        switch arg {
        case "-h", "--help":
            cli.showHelp = true
            return cli
        case "-l", "--list-voices":
            cli.listVoices = true
            return cli
        case "-s", "--stop":
            cli.stopSpeech = true
            return cli
        case "-v", "--voice":
            i += 1
            if i < args.count {
                cli.voice = args[i]
            }
        case "-p", "--port":
            i += 1
            if i < args.count, let port = Int(args[i]) {
                cli.port = port
            }
        case "-H", "--host":
            i += 1
            if i < args.count {
                cli.host = args[i]
            }
        case "-r", "--raw":
            cli.rawOutput = true
        case "-q", "--quiet":
            cli.quiet = true
        default:
            if arg.hasPrefix("-") {
                FileHandle.standardError.write("Unknown option: \(arg)\n".data(using: .utf8)!)
            } else {
                positionalArgs.append(arg)
            }
        }
        i += 1
    }
    
    cli.text = positionalArgs.joined(separator: " ")
    return cli
}

func findFFPlay() -> String? {
    let paths = [
        "/opt/homebrew/bin/ffplay",
        "/usr/local/bin/ffplay",
        "/usr/bin/ffplay"
    ]
    for path in paths {
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }
    return nil
}

func playWithFFPlay(client: TTSClient, text: String, voice: String?) async throws {
    guard let ffplayPath = findFFPlay() else {
        FileHandle.standardError.write("Error: ffplay not found. Install ffmpeg or use --raw mode.\n".data(using: .utf8)!)
        exit(1)
    }
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffplayPath)
    process.arguments = [
        "-f", "s16le",
        "-ar", "24000",
        "-ch_layout", "mono",
        "-nodisp",
        "-autoexit",
        "-loglevel", "quiet",
        "-i", "pipe:0"
    ]
    
    let inputPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    
    try process.run()
    
    let stream = client.streamSpeech(text: text, voice: voice)
    
    for try await chunk in stream {
        inputPipe.fileHandleForWriting.write(chunk)
    }
    
    inputPipe.fileHandleForWriting.closeFile()
    process.waitUntilExit()
}

func outputRaw(client: TTSClient, text: String, voice: String?) async throws {
    let stream = client.streamSpeech(text: text, voice: voice)
    
    for try await chunk in stream {
        FileHandle.standardOutput.write(chunk)
    }
}

func main() async {
    let cli = parseArgs()
    
    if cli.showHelp {
        printUsage()
        exit(0)
    }
    
    if cli.listVoices {
        print("Available voices:")
        for voice in TTSClient.availableVoices {
            print("  \(voice)")
        }
        exit(0)
    }
    
    let client = TTSClient(host: cli.host, port: cli.port)
    
    if cli.stopSpeech {
        do {
            try await client.stop()
            if !cli.quiet {
                FileHandle.standardError.write("Speech stopped.\n".data(using: .utf8)!)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write("Error stopping speech: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    
    // Get text from args or stdin
    var text = cli.text
    
    if text.isEmpty {
        // Check if stdin has data (isatty returns 0 when NOT a tty, i.e., piped input)
        if isatty(STDIN_FILENO) == 0 {
            if let stdinData = try? FileHandle.standardInput.readToEnd(),
               let stdinText = String(data: stdinData, encoding: .utf8) {
                text = stdinText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    
    if text.isEmpty {
        FileHandle.standardError.write("Error: No text provided. Use ptts --help for usage.\n".data(using: .utf8)!)
        exit(1)
    }
    
    // Validate voice if specified
    if let voice = cli.voice, !TTSClient.availableVoices.contains(voice) {
        FileHandle.standardError.write("Warning: Unknown voice '\(voice)'\n".data(using: .utf8)!)
    }
    
    // Check server health
    do {
        let healthy = try await client.healthCheck()
        if !healthy {
            throw TTSError.serverNotRunning
        }
    } catch {
        FileHandle.standardError.write("Error: \(TTSError.serverNotRunning.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
    
    // Speak
    do {
        if cli.rawOutput {
            try await outputRaw(client: client, text: text, voice: cli.voice)
        } else {
            try await playWithFFPlay(client: client, text: text, voice: cli.voice)
        }
    } catch {
        FileHandle.standardError.write("Error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Run async main
let semaphore = DispatchSemaphore(value: 0)
Task {
    await main()
    semaphore.signal()
}
semaphore.wait()

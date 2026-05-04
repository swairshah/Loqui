import Foundation
import Network

public enum LoquiSocketPaths {
    public static var appSupportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Loqui", isDirectory: true)
    }

    public static var socketPath: String {
        appSupportDirectory.appendingPathComponent("loqui.sock").path
    }

    public static func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: appSupportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

public struct LoquiRequest: Codable {
    public let type: String
    public let text: String?
    public let voice: String?
    public let sourceApp: String?
    public let sessionId: String?
    public let pid: Int?

    public init(
        type: String,
        text: String? = nil,
        voice: String? = nil,
        sourceApp: String? = nil,
        sessionId: String? = nil,
        pid: Int? = nil
    ) {
        self.type = type
        self.text = text
        self.voice = voice
        self.sourceApp = sourceApp
        self.sessionId = sessionId
        self.pid = pid
    }
}

public struct LoquiResponse: Codable {
    public let ok: Bool
    public let error: String?
    public let queued: Int?
    public let pending: Int?
    public let playing: Bool?
    public let currentQueue: String?
    public let voices: [String]?
    public let audioBase64: String?
    public let contentType: String?
}

/// Client for communicating with the Loqui local API.
public class TTSClient {
    public let socketPath: String

    public init(socketPath: String = LoquiSocketPaths.socketPath) {
        self.socketPath = socketPath
    }

    /// Available voices
    public static let availableVoices = ["alba", "vera", "paul", "charles", "michael", "anna", "fantine", "eponine", "cosette", "eve", "george", "mary", "marius", "javert", "azelma", "caro_davy", "peter_yearsley", "stuart_bell"]

    /// Check if server is running
    public func healthCheck() async throws -> Bool {
        try await send(.init(type: "health")).ok
    }

    /// Stream TTS audio as raw PCM (s16le, 24kHz, mono)
    /// Returns an AsyncThrowingStream of Data chunks
    public func streamSpeech(text: String, voice: String = "alba") -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let data = try await synthesize(text: text, voice: voice)
                    let chunkSize = 4096
                    var offset = 0
                    while offset < data.count {
                        let end = min(offset + chunkSize, data.count)
                        continuation.yield(data.subdata(in: offset..<end))
                        offset = end
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Synthesize text and return complete raw PCM audio data.
    public func synthesize(text: String, voice: String = "alba") async throws -> Data {
        let response = try await send(.init(type: "raw", text: text, voice: voice), timeout: 60)
        guard response.ok else {
            throw TTSError.serverError(response.error ?? "Synthesis failed")
        }
        guard let audioBase64 = response.audioBase64,
              let data = Data(base64Encoded: audioBase64) else {
            throw TTSError.invalidResponse
        }
        return data
    }

    /// Synthesize text and return complete WAV audio data.
    public func generate(text: String, voice: String = "alba") async throws -> Data {
        let response = try await send(.init(type: "generate", text: text, voice: voice), timeout: 60)
        guard response.ok else {
            throw TTSError.serverError(response.error ?? "Synthesis failed")
        }
        guard let audioBase64 = response.audioBase64,
              let data = Data(base64Encoded: audioBase64) else {
            throw TTSError.invalidResponse
        }
        return data
    }

    /// Stop current speech and active synthesis requests.
    public func stop() async throws {
        let response = try await send(.init(type: "stop"))
        guard response.ok else {
            throw TTSError.serverError(response.error ?? "Stop failed")
        }
    }

    public func send(_ request: LoquiRequest, timeout: TimeInterval = 3.0) async throws -> LoquiResponse {
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)

        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "loqui.client")
            var resumed = false
            var buffer = Data()

            let timeoutWork = DispatchWorkItem {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(throwing: TTSError.serverError("Loqui socket timeout"))
            }

            func resolve(_ result: Result<LoquiResponse, Error>) {
                guard !resumed else { return }
                resumed = true
                timeoutWork.cancel()
                connection.cancel()
                continuation.resume(with: result)
            }

            func parseResponse(_ data: Data) {
                guard !data.isEmpty else {
                    resolve(.failure(TTSError.serverError("Empty Loqui response")))
                    return
                }

                do {
                    resolve(.success(try JSONDecoder().decode(LoquiResponse.self, from: data)))
                } catch {
                    resolve(.failure(TTSError.serverError("Invalid Loqui response")))
                }
            }

            func receiveResponse() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error {
                        resolve(.failure(error))
                        return
                    }

                    if let data, !data.isEmpty {
                        buffer.append(data)
                        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                            parseResponse(Data(buffer.prefix(upTo: newlineIndex)))
                            return
                        }
                    }

                    if isComplete {
                        parseResponse(buffer)
                    } else {
                        receiveResponse()
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    do {
                        var payload = try JSONEncoder().encode(request)
                        payload.append(0x0A)
                        connection.send(content: payload, completion: .contentProcessed { error in
                            if let error {
                                resolve(.failure(error))
                                return
                            }
                            receiveResponse()
                        })
                    } catch {
                        resolve(.failure(error))
                    }

                case .failed(let error):
                    resolve(.failure(error))

                case .cancelled:
                    break

                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            connection.start(queue: queue)
        }
    }
}

public enum TTSError: Error, LocalizedError {
    case serverNotRunning
    case serverError(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return "Loqui server is not running. Start the Loqui app first."
        case .serverError(let message):
            return "Server error: \(message)"
        case .invalidResponse:
            return "Invalid response from server"
        }
    }
}

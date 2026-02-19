import SwiftUI
import AppKit
import ServiceManagement
import Carbon.HIToolbox
import Network
import Darwin
import CoreAudio

@main
struct LoquiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // Empty scene - we manage the settings window manually for menubar apps
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var serverProcess: Process?
    var isServerRunning = false
    var settingsWindow: NSWindow?
    var hotKeyRef: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var speechCoordinator: SpeechPlaybackCoordinator?
    var localBroker: LocalSpeechBroker?
    var micMonitor: MicrophoneActivityMonitor?
    let brokerPort = 18081
    
    // Configuration
    let serverHost = "127.0.0.1"
    
    // Dock icon visibility (defaults to true)
    var showDockIcon: Bool {
        get { 
            // Default to true if not set
            if UserDefaults.standard.object(forKey: "showDockIcon") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "showDockIcon") 
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "showDockIcon")
            updateDockIconVisibility()
        }
    }
    
    // Read from UserDefaults (synced with @AppStorage in SettingsView)
    var serverPort: Int {
        let port = UserDefaults.standard.integer(forKey: "ttsPort")
        return port > 0 ? port : 18080
    }
    
    var selectedVoice: String {
        UserDefaults.standard.string(forKey: "ttsVoice") ?? "fantine"
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupGlobalShortcut()
        updateDockIconVisibility()

        speechCoordinator = SpeechPlaybackCoordinator(
            hostProvider: { [weak self] in self?.serverHost ?? "127.0.0.1" },
            portProvider: { [weak self] in self?.serverPort ?? 18080 },
            defaultVoiceProvider: { [weak self] in self?.selectedVoice ?? "fantine" }
        )

        micMonitor = MicrophoneActivityMonitor { [weak self] isActive in
            self?.speechCoordinator?.setMicrophoneActive(isActive)
        }
        micMonitor?.start()

        startLocalBroker()
        startServer()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // When dock icon is clicked, open settings
        openSettings()
        return true
    }
    
    func updateDockIconVisibility() {
        if showDockIcon {
            NSApp.setActivationPolicy(.regular)
            // Force the dock to update
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        micMonitor?.stop()
        localBroker?.stop()
        speechCoordinator?.stopAll()
        stopServer()
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
    
    // MARK: - Menu Bar
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(running: false)
        
        let menu = NSMenu()
        
        let statusMenuItem = NSMenuItem(title: "Server: Starting...", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let stopSpeechItem = NSMenuItem(title: "Stop Speech", action: #selector(stopCurrentSpeech), keyEquivalent: ".")
        stopSpeechItem.keyEquivalentModifierMask = [.command]
        menu.addItem(stopSpeechItem)
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Restart Server", action: #selector(restartServer), keyEquivalent: "r"))
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        
        menu.addItem(NSMenuItem.separator())
        
        let dockIconItem = NSMenuItem(title: "Show Dock Icon", action: #selector(toggleDockIcon), keyEquivalent: "")
        dockIconItem.tag = 101
        dockIconItem.state = showDockIcon ? .on : .off
        menu.addItem(dockIconItem)
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Quit Loqui", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    func updateStatusIcon(running: Bool) {
        if let button = statusItem.button {
            let imageName = running ? "menubar-running" : "menubar-stopped"
            if let img = loadMenuBarImage(named: imageName) {
                img.isTemplate = true
                button.image = img
            } else {
                // Fallback to SF Symbols
                button.image = NSImage(systemSymbolName: running ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                       accessibilityDescription: running ? "TTS Running" : "TTS Stopped")
            }
        }
        
        if let menu = statusItem.menu,
           let statusItem = menu.item(withTag: 100) {
            statusItem.title = running ? "Server: Running on port \(serverPort)" : "Server: Stopped"
        }
        
        isServerRunning = running
    }
    
    func loadMenuBarImage(named name: String) -> NSImage? {
        // Try bundled Resources first
        if let resourcePath = Bundle.main.resourcePath {
            let url1x = URL(fileURLWithPath: resourcePath).appendingPathComponent("\(name).png")
            let url2x = URL(fileURLWithPath: resourcePath).appendingPathComponent("\(name)@2x.png")
            if let img = NSImage(contentsOf: url1x) {
                // Attach @2x representation if available
                if let rep2x = NSImageRep(contentsOf: url2x) {
                    img.addRepresentation(rep2x)
                }
                img.size = NSSize(width: 22, height: 22)
                return img
            }
        }
        // Fallback: load from the executable's directory (dev builds)
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
        if let dir = execDir {
            let url = dir.appendingPathComponent("\(name).png")
            if let img = NSImage(contentsOf: url) {
                img.size = NSSize(width: 22, height: 22)
                return img
            }
        }
        return nil
    }
    
    // MARK: - Global Shortcut (Cmd+.)
    
    func setupGlobalShortcut() {
        // Use Carbon API for true global hotkey that works everywhere
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            appDelegate.stopCurrentSpeech()
            return noErr
        }
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &eventHandler)
        
        // Register Cmd+. hotkey
        // Key code 47 = period (.)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C4F5149), id: 1) // "LOQI"
        let modifiers: UInt32 = UInt32(cmdKey)
        RegisterEventHotKey(47, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func startLocalBroker() {
        guard let coordinator = speechCoordinator else { return }
        do {
            let broker = try LocalSpeechBroker(port: brokerPort, coordinator: coordinator)
            broker.start()
            localBroker = broker
            print("Loqui: Local broker listening on 127.0.0.1:\(brokerPort)")
        } catch {
            print("Loqui: Failed to start local broker: \(error)")
        }
    }
    
    @objc func stopCurrentSpeech() {
        // Centralized stop: clear broker queue, stop active Loqui playback, stop current synth request.
        speechCoordinator?.stopAll()
    }
    
    // MARK: - Server Management
    
    func getServerBinaryPath() -> URL? {
        // First, check if bundled in app Resources
        if let resourcePath = Bundle.main.resourcePath {
            let bundledPath = URL(fileURLWithPath: resourcePath).appendingPathComponent("pocket-tts-cli")
            if FileManager.default.fileExists(atPath: bundledPath.path) {
                return bundledPath
            }
        }
        
        // Also check forResource (for when it's a proper resource)
        if let bundledPath = Bundle.main.url(forResource: "pocket-tts-cli", withExtension: nil) {
            return bundledPath
        }
        
        // Fallback: check common locations
        let possiblePaths = [
            "/usr/local/bin/pocket-tts-cli",
            "/opt/homebrew/bin/pocket-tts-cli",
            NSHomeDirectory() + "/.local/bin/pocket-tts-cli",
            // Development path
            NSHomeDirectory() + "/work/ml/pocket-tts/target/release/pocket-tts-cli"
        ]
        
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        
        return nil
    }
    
    func getBundledModelsPath() -> URL? {
        // Check if models are bundled in app Resources
        if let resourcePath = Bundle.main.resourcePath {
            let modelsPath = URL(fileURLWithPath: resourcePath).appendingPathComponent("models")
            let weightsFile = modelsPath.appendingPathComponent("tts_b6369a24.safetensors")
            if FileManager.default.fileExists(atPath: weightsFile.path) {
                return modelsPath
            }
        }
        return nil
    }
    
    func getModelCachePath() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let pocketTTSDir = appSupport.appendingPathComponent("Loqui")
        try? FileManager.default.createDirectory(at: pocketTTSDir, withIntermediateDirectories: true)
        return pocketTTSDir
    }
    
    /// Set up HuggingFace cache structure from bundled models
    /// This copies bundled model files into the HF cache format so the CLI finds them
    func setupBundledModelsCache() {
        guard let bundledModels = getBundledModelsPath() else { return }
        
        let fm = FileManager.default
        let hfHome = getModelCachePath()
        let hubDir = hfHome.appendingPathComponent("hub")
        
        // Model file mappings: (bundled name, repo, revision, path in snapshot, blob hash)
        let modelFiles: [(String, String, String, String, String)] = [
            // Main model weights
            ("tts_b6369a24.safetensors", "models--kyutai--pocket-tts", 
             "427e3d61b276ed69fdd03de0d185fa8a8d97fc5b", "tts_b6369a24.safetensors",
             "a4246e239af0f35a1c495b6d180961a6f10b379dc24dd537f64c695c08e4e216"),
            // Tokenizer
            ("tokenizer.model", "models--kyutai--pocket-tts-without-voice-cloning",
             "d4fdd22ae8c8e1cb3634e150ebeff1dab2d16df3", "tokenizer.model",
             "d461765ae179566678c93091c5fa6f2984c31bbe990bf1aa62d92c64d91bc3f6"),
            // Voice embeddings
            ("fantine.safetensors", "models--kyutai--pocket-tts-without-voice-cloning",
             "2578fed2380333b621689eaed6fe144cf69dfeb3", "embeddings/fantine.safetensors",
             "b6918a2ece002d2d9037ff53c4ea38730175e8798786658b0958443edf49d355"),
            ("alba.safetensors", "models--kyutai--pocket-tts-without-voice-cloning",
             "2578fed2380333b621689eaed6fe144cf69dfeb3", "embeddings/alba.safetensors",
             "ad234695323e4030336b6afc8a050c97e3110603e11ecd8226d9562488300a50"),
        ]
        
        for (bundledName, repo, revision, snapshotPath, blobHash) in modelFiles {
            let sourceFile = bundledModels.appendingPathComponent(bundledName)
            guard fm.fileExists(atPath: sourceFile.path) else { continue }
            
            let repoDir = hubDir.appendingPathComponent(repo)
            let blobsDir = repoDir.appendingPathComponent("blobs")
            let snapshotDir = repoDir.appendingPathComponent("snapshots").appendingPathComponent(revision)
            
            // Create directories
            try? fm.createDirectory(at: blobsDir, withIntermediateDirectories: true)
            let snapshotFileDir = snapshotDir.appendingPathComponent(snapshotPath).deletingLastPathComponent()
            try? fm.createDirectory(at: snapshotFileDir, withIntermediateDirectories: true)
            
            // Copy to blobs if not exists
            let blobFile = blobsDir.appendingPathComponent(blobHash)
            if !fm.fileExists(atPath: blobFile.path) {
                try? fm.copyItem(at: sourceFile, to: blobFile)
            }
            
            // Create symlink in snapshot
            let snapshotFile = snapshotDir.appendingPathComponent(snapshotPath)
            if !fm.fileExists(atPath: snapshotFile.path) {
                // Calculate relative path from snapshot to blob
                let relativePath = "../../blobs/\(blobHash)"
                try? fm.createSymbolicLink(atPath: snapshotFile.path, withDestinationPath: relativePath)
            }
        }
    }
    
    func startServer() {
        guard getServerBinaryPath() != nil else {
            showAlert(title: "Server Binary Not Found", 
                     message: "Could not find pocket-tts-cli. Please ensure it's installed or bundled with the app.")
            updateStatusIcon(running: false)
            return
        }
        
        // Set up bundled models in HF cache format
        setupBundledModelsCache()
        
        let process = Process()
        
        // Use /bin/bash to ensure we cd into the right directory before running
        // This is more reliable than Process.currentDirectoryURL
        guard let resourcePath = Bundle.main.resourcePath else {
            showAlert(title: "Resource Path Not Found",
                     message: "Could not find app Resources directory.")
            updateStatusIcon(running: false)
            return
        }
        
        let voicePath = "\(resourcePath)/models/embeddings/\(selectedVoice).safetensors"
        
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "cd '\(resourcePath)' && ./pocket-tts-cli serve --port \(serverPort) --host \(serverHost) --voice '\(voicePath)'"
        ]
        
        print("Loqui: Starting server from: \(resourcePath)")
        print("Loqui: Using voice: \(voicePath)")
        
        // Set up environment
        var env = ProcessInfo.processInfo.environment
        
        // Use app's cache directory for HuggingFace cache
        let cacheDir = getModelCachePath()
        env["HF_HOME"] = cacheDir.path
        
        // Set voices directory for local voice resolution
        env["POCKET_TTS_VOICES_DIR"] = "\(resourcePath)/models/embeddings"
        
        process.environment = env
        
        // Capture output for debugging
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.updateStatusIcon(running: false)
                if process.terminationStatus != 0 {
                    self?.showAlert(title: "Server Stopped", 
                                   message: "TTS server exited with code \(process.terminationStatus)")
                }
            }
        }
        
        do {
            try process.run()
            serverProcess = process
            
            // Wait a bit then check health
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.checkServerHealth()
            }
        } catch {
            showAlert(title: "Failed to Start Server", message: error.localizedDescription)
            updateStatusIcon(running: false)
        }
    }
    
    func checkServerHealth() {
        Task {
            do {
                let url = URL(string: "http://\(serverHost):\(serverPort)/health")!
                let (_, response) = try await URLSession.shared.data(from: url)
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    await MainActor.run {
                        updateStatusIcon(running: true)
                    }
                } else {
                    // Retry after a delay
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    checkServerHealth()
                }
            } catch {
                // Server not ready yet, retry
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if serverProcess?.isRunning == true {
                    checkServerHealth()
                }
            }
        }
    }
    
    func stopServer() {
        serverProcess?.terminate()
        serverProcess = nil
        updateStatusIcon(running: false)
    }
    
    @objc func restartServer() {
        stopServer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startServer()
        }
    }
    
    @objc func toggleDockIcon() {
        showDockIcon = !showDockIcon
        // Update menu item state
        if let menu = statusItem.menu, let item = menu.item(withTag: 101) {
            item.state = showDockIcon ? .on : .off
        }
    }
    
    // MARK: - Actions
    
    @objc func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let hostingController = NSHostingController(rootView: settingsView)
            
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Loqui"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.setContentSize(NSSize(width: 520, height: 480))
            window.minSize = NSSize(width: 420, height: 380)
            window.center()
            
            settingsWindow = window
        }
        
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func quitApp() {
        stopServer()
        NSApp.terminate(nil)
    }
    
    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Local Broker & Playback

private struct SpeechJob {
    let historyEntryId: UUID
    let text: String
    let voice: String
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
}

private struct BrokerRequest: Decodable {
    let type: String
    let text: String?
    let voice: String?
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
}

private struct BrokerResponse: Encodable {
    let ok: Bool
    let error: String?
    let queued: Int?
    let pending: Int?
    let playing: Bool?
    let currentQueue: String?

    static func success(
        queued: Int? = nil,
        pending: Int? = nil,
        playing: Bool? = nil,
        currentQueue: String? = nil
    ) -> BrokerResponse {
        BrokerResponse(
            ok: true,
            error: nil,
            queued: queued,
            pending: pending,
            playing: playing,
            currentQueue: currentQueue
        )
    }

    static func failure(_ message: String) -> BrokerResponse {
        BrokerResponse(ok: false, error: message, queued: nil, pending: nil, playing: nil, currentQueue: nil)
    }
}

enum RequestPlaybackStatus: String, Codable {
    case queued
    case playing
    case played
    case interrupted
    case cancelled
    case failed

    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .playing: return "Playing"
        case .played: return "Played"
        case .interrupted: return "Interrupted"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }

    var isInQueue: Bool {
        self == .queued || self == .playing
    }

    var tintColor: Color {
        switch self {
        case .queued: return .secondary
        case .playing: return .blue
        case .played: return .green
        case .interrupted: return .orange
        case .cancelled: return .orange
        case .failed: return .red
        }
    }
}

struct RequestHistoryEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let text: String
    let voice: String?
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
    var status: RequestPlaybackStatus

    init(
        id: UUID = UUID(),
        timestamp: Date,
        text: String,
        voice: String?,
        sourceApp: String?,
        sessionId: String?,
        pid: Int?,
        status: RequestPlaybackStatus
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.voice = voice
        self.sourceApp = sourceApp
        self.sessionId = sessionId
        self.pid = pid
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, text, voice, sourceApp, sessionId, pid, status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        text = try container.decode(String.self, forKey: .text)
        voice = try container.decodeIfPresent(String.self, forKey: .voice)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        // Backward compatibility: old entries had no status, treat as already played
        status = try container.decodeIfPresent(RequestPlaybackStatus.self, forKey: .status) ?? .played
    }
}

final class RequestHistoryStore: ObservableObject {
    static let shared = RequestHistoryStore()

    @Published private(set) var entries: [RequestHistoryEntry] = []
    private let maxEntries = 250
    private let historyFileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let loquiDir = appSupport.appendingPathComponent("Loqui", isDirectory: true)
        historyFileURL = loquiDir.appendingPathComponent("request-history.json")
        _ = syncOnMain { () -> Bool in
            loadFromDisk()
            return true
        }
    }

    @discardableResult
    func add(text: String, voice: String?, sourceApp: String?, sessionId: String?, pid: Int?) -> UUID {
        let entry = RequestHistoryEntry(
            timestamp: Date(),
            text: text,
            voice: voice,
            sourceApp: sourceApp,
            sessionId: sessionId,
            pid: pid,
            status: .queued
        )

        _ = syncOnMain { () -> Bool in
            entries.insert(entry, at: 0)
            if entries.count > maxEntries {
                entries.removeLast(entries.count - maxEntries)
            }
            persist()
            return true
        }

        return entry.id
    }

    func updateStatus(
        id: UUID,
        to newStatus: RequestPlaybackStatus,
        unlessCurrentIn blockedStatuses: Set<RequestPlaybackStatus> = []
    ) {
        _ = syncOnMain { () -> Bool in
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                return false
            }

            let current = entries[index].status
            if blockedStatuses.contains(current) {
                return false
            }

            if current != newStatus {
                entries[index].status = newStatus
                persist()
            }
            return true
        }
    }

    func clear() {
        _ = syncOnMain { () -> Bool in
            entries.removeAll()
            persist()
            return true
        }
    }

    private func syncOnMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }

        return DispatchQueue.main.sync(execute: work)
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: historyFileURL)
            let decoded = try JSONDecoder().decode([RequestHistoryEntry].self, from: data)
            entries = Array(decoded.prefix(maxEntries))
        } catch {
            print("Loqui: Failed to load request history: \(error)")
        }
    }

    private func persist() {
        do {
            let directory = historyFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: historyFileURL, options: [.atomic])
        } catch {
            print("Loqui: Failed to persist request history: \(error)")
        }
    }
}

final class MicrophoneActivityMonitor {
    private let pollQueue = DispatchQueue(label: "loqui.mic.monitor")
    private var timer: DispatchSourceTimer?

    private let pollInterval: TimeInterval
    private let releaseDelay: TimeInterval
    private let onActivityChanged: (Bool) -> Void

    private var isActive = false
    private var keepActiveUntil = Date.distantPast

    init(
        pollInterval: TimeInterval = 0.25,
        releaseDelay: TimeInterval = 0.8,
        onActivityChanged: @escaping (Bool) -> Void
    ) {
        self.pollInterval = pollInterval
        self.releaseDelay = releaseDelay
        self.onActivityChanged = onActivityChanged
    }

    func start() {
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.pollMicrophoneUsage()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        setActive(false)
    }

    private func pollMicrophoneUsage() {
        // Detect whether the default input device is currently running.
        // This does not open the microphone from Loqui itself.
        let inUse = isDefaultInputDeviceRunning()
        let now = Date()

        if inUse {
            keepActiveUntil = now.addingTimeInterval(releaseDelay)
            if !isActive {
                setActive(true)
            }
        } else if isActive, now >= keepActiveUntil {
            setActive(false)
        }
    }

    private func isDefaultInputDeviceRunning() -> Bool {
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let getDeviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            0,
            nil,
            &size,
            &deviceID
        )

        guard getDeviceStatus == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return false
        }

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)

        let getRunningStatus = AudioObjectGetPropertyData(
            deviceID,
            &runningAddress,
            0,
            nil,
            &size,
            &running
        )

        guard getRunningStatus == noErr else {
            return false
        }

        return running != 0
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active

        DispatchQueue.main.async {
            self.onActivityChanged(active)
        }
    }
}


final class SpeechPlaybackCoordinator {
    private let queue = DispatchQueue(label: "loqui.playback.coordinator")

    // Per-source queue buckets keyed by app + session
    private var queuesByKey: [String: [SpeechJob]] = [:]
    private var queueOrder: [String] = []

    private var isPlaying = false
    private var currentProcess: Process?
    private var currentJobHistoryId: UUID?
    private var currentQueueKey: String?
    private var currentRunNonce: UUID?

    private var isMicrophoneActive = false

    // Auto voice assignment for queues that don't specify voice.
    private let autoVoicePool = ["fantine", "alba", "cosette", "marius", "azelma"]
    private var autoVoiceByQueueKey: [String: String] = [:]
    private var autoVoiceCycleIndex = 0

    private let hostProvider: () -> String
    private let portProvider: () -> Int
    private let defaultVoiceProvider: () -> String

    init(hostProvider: @escaping () -> String,
         portProvider: @escaping () -> Int,
         defaultVoiceProvider: @escaping () -> String) {
        self.hostProvider = hostProvider
        self.portProvider = portProvider
        self.defaultVoiceProvider = defaultVoiceProvider
    }

    func enqueue(text: String,
                 voice: String?,
                 sourceApp: String?,
                 sessionId: String?,
                 pid: Int?) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return state().pending
        }

        let key = queueKey(sourceApp: sourceApp, sessionId: sessionId)

        return queue.sync {
            let resolvedVoice = resolveVoiceForQueueLocked(requestedVoice: voice, queueKey: key)

            let historyEntryId = RequestHistoryStore.shared.add(
                text: trimmed,
                voice: resolvedVoice,
                sourceApp: sourceApp,
                sessionId: sessionId,
                pid: pid
            )

            let job = SpeechJob(
                historyEntryId: historyEntryId,
                text: trimmed,
                voice: resolvedVoice,
                sourceApp: sourceApp,
                sessionId: sessionId,
                pid: pid
            )

            if queuesByKey[key] == nil {
                queuesByKey[key] = []
                queueOrder.append(key)
            }
            queuesByKey[key]?.append(job)

            startNextIfNeededLocked()
            return pendingCountLocked() + (isPlaying ? 1 : 0)
        }
    }

    func state() -> (pending: Int, playing: Bool, currentQueue: String?) {
        queue.sync {
            (pendingCountLocked() + (isPlaying ? 1 : 0), isPlaying, currentQueueKey)
        }
    }

    func stopAll() {
        let state = queue.sync { () -> (pending: [UUID], active: UUID?) in
            let pendingIds = allPendingHistoryIdsLocked()
            let activeId = currentJobHistoryId

            queuesByKey.removeAll()
            queueOrder.removeAll()
            autoVoiceByQueueKey.removeAll()
            terminateCurrentProcessLocked()
            currentJobHistoryId = nil
            currentQueueKey = nil
            currentRunNonce = nil
            isPlaying = false

            return (pending: pendingIds, active: activeId)
        }

        for id in state.pending {
            RequestHistoryStore.shared.updateStatus(id: id, to: .cancelled)
        }

        if let activeId = state.active {
            RequestHistoryStore.shared.updateStatus(id: activeId, to: .interrupted)
        }

        Task {
            await sendStopToServer()
        }
    }

    func setMicrophoneActive(_ active: Bool) {
        queue.async {
            self.handleMicrophoneStateChangeLocked(active)
        }
    }

    private func handleMicrophoneStateChangeLocked(_ active: Bool) {
        guard active != isMicrophoneActive else { return }
        isMicrophoneActive = active

        if active {
            let activelyPlaying = currentProcess?.isRunning == true

            // Requirement: if mic starts while voice is already playing, cancel all queued work at that moment.
            guard activelyPlaying else { return }

            let pendingIds = allPendingHistoryIdsLocked()
            let activeId = currentJobHistoryId

            queuesByKey.removeAll()
            queueOrder.removeAll()
            autoVoiceByQueueKey.removeAll()
            terminateCurrentProcessLocked()
            currentJobHistoryId = nil
            currentQueueKey = nil
            currentRunNonce = nil
            isPlaying = false

            for id in pendingIds {
                RequestHistoryStore.shared.updateStatus(id: id, to: .cancelled)
            }
            if let activeId {
                RequestHistoryStore.shared.updateStatus(id: activeId, to: .interrupted)
            }
        } else {
            // Mic inactive again, resume queued playback.
            startNextIfNeededLocked()
        }
    }

    private func startNextIfNeededLocked() {
        guard !isPlaying, !isMicrophoneActive else { return }
        guard let (queueKey, job) = dequeueNextJobLocked() else { return }

        isPlaying = true
        currentJobHistoryId = job.historyEntryId
        currentQueueKey = queueKey

        let runNonce = UUID()
        currentRunNonce = runNonce

        RequestHistoryStore.shared.updateStatus(
            id: job.historyEntryId,
            to: .playing,
            unlessCurrentIn: [.cancelled, .interrupted]
        )

        Task { [weak self] in
            await self?.process(job: job, runNonce: runNonce)
        }
    }

    private func process(job: SpeechJob, runNonce: UUID) async {
        var finalStatus: RequestPlaybackStatus = .played

        do {
            let audioData = try await synthesize(job: job)

            guard await waitUntilMicrophoneInactive(runNonce: runNonce) else {
                return
            }
            guard shouldContinue(runNonce: runNonce) else {
                return
            }

            try await play(audioData: audioData)
        } catch {
            finalStatus = .failed
            print("Loqui: Playback error: \(error.localizedDescription)")
        }

        RequestHistoryStore.shared.updateStatus(
            id: job.historyEntryId,
            to: finalStatus,
            unlessCurrentIn: [.cancelled, .interrupted]
        )

        finishCurrent(runNonce: runNonce)
    }

    private func finishCurrent(runNonce: UUID) {
        queue.async {
            guard self.currentRunNonce == runNonce else { return }

            self.currentProcess = nil
            self.currentJobHistoryId = nil
            self.currentQueueKey = nil
            self.currentRunNonce = nil
            self.isPlaying = false
            self.startNextIfNeededLocked()
        }
    }

    private func shouldContinue(runNonce: UUID) -> Bool {
        queue.sync {
            currentRunNonce == runNonce
        }
    }

    private func waitUntilMicrophoneInactive(runNonce: UUID) async -> Bool {
        while true {
            let snapshot = queue.sync { (isMicrophoneActive, currentRunNonce == runNonce) }
            let micActive = snapshot.0
            let runStillValid = snapshot.1

            if !runStillValid {
                return false
            }
            if !micActive {
                return true
            }

            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func synthesize(job: SpeechJob) async throws -> Data {
        let url = URL(string: "http://\(hostProvider()):\(portProvider())/stream")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["text": job.text, "voice": job.voice]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "Loqui", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to synthesize speech"])
        }

        return data
    }

    private func play(audioData: Data) async throws {
        guard let ffplayPath = findFFPlayPath() else {
            throw NSError(domain: "Loqui", code: 404, userInfo: [NSLocalizedDescriptionKey: "ffplay not found"])
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loqui-\(UUID().uuidString).raw")
        try audioData.write(to: tempURL)

        defer {
            try? FileManager.default.removeItem(at: tempURL)
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
            tempURL.path
        ]

        try process.run()

        queue.sync {
            self.currentProcess = process
        }

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
    }

    private func findFFPlayPath() -> String? {
        let paths = [
            "/opt/homebrew/bin/ffplay",
            "/usr/local/bin/ffplay",
            "/usr/bin/ffplay"
        ]

        for path in paths where FileManager.default.fileExists(atPath: path) {
            return path
        }

        return nil
    }

    private func terminateCurrentProcessLocked() {
        guard let process = currentProcess else { return }

        if process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        currentProcess = nil
    }

    private func sendStopToServer() async {
        let stopURL = URL(string: "http://\(hostProvider()):\(portProvider())/stop")!
        var request = URLRequest(url: stopURL)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
    }

    private func resolveVoiceForQueueLocked(requestedVoice: String?, queueKey: String) -> String {
        let trimmedRequested = requestedVoice?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requested = trimmedRequested, !requested.isEmpty {
            return requested
        }

        if let assigned = autoVoiceByQueueKey[queueKey] {
            return assigned
        }

        // Check all already-assigned voices, not just active queues.
        // This ensures different sessions get different voices even if they're
        // not concurrent (e.g., session A finishes before session B starts).
        let usedVoices = Set(autoVoiceByQueueKey.values)

        if let freeVoice = autoVoicePool.first(where: { !usedVoices.contains($0) }) {
            autoVoiceByQueueKey[queueKey] = freeVoice
            return freeVoice
        }

        guard !autoVoicePool.isEmpty else {
            return defaultVoiceProvider()
        }

        let cycled = autoVoicePool[autoVoiceCycleIndex % autoVoicePool.count]
        autoVoiceCycleIndex += 1
        autoVoiceByQueueKey[queueKey] = cycled
        return cycled
    }

    private func queueKey(sourceApp: String?, sessionId: String?) -> String {
        let app = normalizedSourceApp(sourceApp)
        let session = normalizedSessionId(sessionId)
        return "\(app)::\(session)"
    }

    private func normalizedSourceApp(_ sourceApp: String?) -> String {
        let trimmed = sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed! : "unknown"
    }

    private func normalizedSessionId(_ sessionId: String?) -> String {
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed! : "__none__"
    }

    private func dequeueNextJobLocked() -> (String, SpeechJob)? {
        while !queueOrder.isEmpty {
            let key = queueOrder.removeFirst()

            guard var jobs = queuesByKey[key], !jobs.isEmpty else {
                queuesByKey.removeValue(forKey: key)
                continue
            }

            let job = jobs.removeFirst()

            if jobs.isEmpty {
                queuesByKey.removeValue(forKey: key)
            } else {
                queuesByKey[key] = jobs
                queueOrder.append(key)
            }

            return (key, job)
        }

        return nil
    }

    private func allPendingHistoryIdsLocked() -> [UUID] {
        queuesByKey.values.flatMap { $0.map(\.historyEntryId) }
    }

    private func pendingCountLocked() -> Int {
        queuesByKey.values.reduce(0) { $0 + $1.count }
    }
}


final class LocalSpeechBroker {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loqui.local.broker")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let coordinator: SpeechPlaybackCoordinator

    init(port: Int, coordinator: SpeechPlaybackCoordinator) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "Loqui", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid broker port: \(port)"])
        }

        self.listener = try NWListener(using: .tcp, on: nwPort)
        self.coordinator = coordinator
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                break
            case .failed(let error):
                print("Loqui: Broker failed: \(error)")
            default:
                break
            }
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                self.send(response: .failure("Connection error: \(error.localizedDescription)"), on: connection)
                return
            }

            var newBuffer = buffer
            if let data {
                newBuffer.append(data)
            }

            if let range = newBuffer.range(of: Data([0x0A])) {
                let line = newBuffer.subdata(in: 0..<range.lowerBound)
                self.handleLine(line, on: connection)
                return
            }

            if isComplete {
                self.handleLine(newBuffer, on: connection)
                return
            }

            self.receive(on: connection, buffer: newBuffer)
        }
    }

    private func handleLine(_ line: Data, on connection: NWConnection) {
        guard !line.isEmpty else {
            send(response: .failure("Empty request"), on: connection)
            return
        }

        let request: BrokerRequest
        do {
            request = try decoder.decode(BrokerRequest.self, from: line)
        } catch {
            send(response: .failure("Invalid JSON request"), on: connection)
            return
        }

        switch request.type {
        case "health":
            let state = coordinator.state()
            send(response: .success(pending: state.pending, playing: state.playing, currentQueue: state.currentQueue), on: connection)

        case "speak":
            guard let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                send(response: .failure("Missing text"), on: connection)
                return
            }

            let queued = coordinator.enqueue(
                text: text,
                voice: request.voice,
                sourceApp: request.sourceApp,
                sessionId: request.sessionId,
                pid: request.pid
            )
            send(response: .success(queued: queued), on: connection)

        case "stop":
            coordinator.stopAll()
            let state = coordinator.state()
            send(response: .success(pending: state.pending, playing: state.playing, currentQueue: state.currentQueue), on: connection)

        default:
            send(response: .failure("Unknown command: \(request.type)"), on: connection)
        }
    }

    private func send(response: BrokerResponse, on connection: NWConnection) {
        let payload: Data
        do {
            var data = try encoder.encode(response)
            data.append(0x0A)
            payload = data
        } catch {
            let fallback = "{\"ok\":false,\"error\":\"Encoding failed\"}\n"
            connection.send(content: fallback.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - Settings View

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Text("General")
                }

            HistoryView()
                .tabItem {
                    Text("History")
                }

            HelpView()
                .tabItem {
                    Text("Help")
                }

            AboutView()
                .tabItem {
                    Text("About")
                }
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("ttsVoice") var voice = "fantine"
    @AppStorage("ttsPort") var port = 18080
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("showDockIcon") var showDockIcon = true
    @State private var isPreviewPlaying = false
    @State private var portString = ""
    
    // All available voices from kyutai/pocket-tts
    let availableVoices = ["alba", "marius", "javert", "fantine", "cosette", "eponine", "azelma"]
    
    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                    Text("Loqui")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("Local Text-to-Speech")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
            }

            Section("Voice") {
                HStack {
                    Picker("Voice", selection: $voice) {
                        ForEach(availableVoices, id: \.self) { v in
                            Text(v.capitalized).tag(v)
                        }
                    }
                    .pickerStyle(.menu)

                    Spacer()

                    Button(isPreviewPlaying ? "Playing…" : "Preview") {
                        previewVoice(voice)
                    }
                    .disabled(isPreviewPlaying)
                }
            }

            Section("Server") {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("", text: $portString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .multilineTextAlignment(.center)
                    Button("Apply") {
                        if let newPort = Int(portString), newPort > 0 {
                            port = newPort
                            restartServerForSettingsChange()
                        }
                    }
                    .disabled(Int(portString) == port)
                }
            }

            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        setLaunchAtLogin(enabled: newValue)
                    }

                Toggle("Show Dock Icon", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _ in
                        updateDockIcon()
                    }
            }

            Section("Shortcut") {
                HStack {
                    Text("Stop Speech")
                        .foregroundColor(.secondary)
                    Spacer()
                    KeyboardShortcutView(keys: ["⌘", "."])
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            portString = String(port)
        }
    }
    
    func updateDockIcon() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.updateDockIconVisibility()
            // Update menu item state
            if let menu = appDelegate.statusItem.menu, let item = menu.item(withTag: 101) {
                item.state = showDockIcon ? .on : .off
            }
        }
    }
    
    func restartServerForSettingsChange() {
        // Find the app delegate and restart the server
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.restartServer()
        }
    }
    
    func previewVoice(_ voiceName: String) {
        guard !isPreviewPlaying else { return }
        isPreviewPlaying = true
        
        let text = "Hi, this is \(voiceName.capitalized)."
        
        Task {
            do {
                // Call the TTS server to get audio
                let url = URL(string: "http://127.0.0.1:\(port)/stream")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                
                let body = ["text": text, "voice": voiceName]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                
                let (data, _) = try await URLSession.shared.data(for: request)
                
                // Write PCM data to temp file and play with afplay
                let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("voice_preview.raw")
                try data.write(to: tempFile)
                
                // Convert and play using ffplay
                let ffplayPath = "/opt/homebrew/bin/ffplay"
                if FileManager.default.fileExists(atPath: ffplayPath) {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: ffplayPath)
                    process.arguments = [
                        "-f", "s16le",
                        "-ar", "24000",
                        "-ch_layout", "mono",
                        "-nodisp",
                        "-autoexit",
                        "-loglevel", "quiet",
                        tempFile.path
                    ]
                    process.terminationHandler = { _ in
                        DispatchQueue.main.async {
                            self.isPreviewPlaying = false
                        }
                        try? FileManager.default.removeItem(at: tempFile)
                    }
                    try process.run()
                } else {
                    isPreviewPlaying = false
                }
            } catch {
                print("Voice preview error: \(error)")
                await MainActor.run {
                    isPreviewPlaying = false
                }
            }
        }
    }
    
    func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to set launch at login: \(error)")
            }
        }
    }
}

struct HistoryView: View {
    @StateObject private var historyStore = RequestHistoryStore.shared
    @State private var searchText = ""
    @State private var selectedAppFilter = Self.allAppsToken
    @State private var selectedSessionFilter = Self.allSessionsToken

    private static let allAppsToken = "__all_apps__"
    private static let allSessionsToken = "__all_sessions__"
    private static let noSessionToken = "__no_session__"

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private var availableApps: [String] {
        let apps = Set(historyStore.entries.map { normalizedAppName($0.sourceApp) })
        return apps.sorted()
    }

    private var availableSessions: [String] {
        let sessions = Set(historyStore.entries.compactMap { normalizedSessionId($0.sessionId) })
        return sessions.sorted()
    }

    private var appFilterOptions: [String] {
        [Self.allAppsToken] + availableApps
    }

    private var sessionFilterOptions: [String] {
        var options = [Self.allSessionsToken]
        if historyStore.entries.contains(where: { normalizedSessionId($0.sessionId) == nil }) {
            options.append(Self.noSessionToken)
        }
        options.append(contentsOf: availableSessions)
        return options
    }

    private var isFiltering: Bool {
        !searchText.isEmpty || selectedAppFilter != Self.allAppsToken || selectedSessionFilter != Self.allSessionsToken
    }

    private var filteredEntries: [RequestHistoryEntry] {
        historyStore.entries.filter { entry in
            if !searchText.isEmpty {
                let searchLower = searchText.lowercased()
                let textMatches = entry.text.lowercased().contains(searchLower)
                let appMatches = normalizedAppName(entry.sourceApp).lowercased().contains(searchLower)
                let sessionMatches = (entry.sessionId?.lowercased().contains(searchLower) ?? false)
                if !textMatches && !appMatches && !sessionMatches {
                    return false
                }
            }

            if selectedAppFilter != Self.allAppsToken,
               normalizedAppName(entry.sourceApp) != selectedAppFilter {
                return false
            }

            if selectedSessionFilter == Self.noSessionToken {
                return normalizedSessionId(entry.sessionId) == nil
            }

            if selectedSessionFilter != Self.allSessionsToken,
               normalizedSessionId(entry.sessionId) != selectedSessionFilter {
                return false
            }

            return true
        }
    }

    private var queueEntries: [RequestHistoryEntry] {
        filteredEntries
            .filter { $0.status.isInQueue }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var completedEntries: [RequestHistoryEntry] {
        filteredEntries.filter { !$0.status.isInQueue }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("History")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("\(queueEntries.count) queued · \(completedEntries.count) completed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if isFiltering {
                        Button("Reset Filters") {
                            searchText = ""
                            selectedAppFilter = Self.allAppsToken
                            selectedSessionFilter = Self.allSessionsToken
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                    }
                    Button {
                        historyStore.clear()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(historyStore.entries.isEmpty)
                    .help("Clear all history")
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    TextField("Search text, app, or session...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)

                HStack(spacing: 8) {
                    Picker("App", selection: $selectedAppFilter) {
                        ForEach(appFilterOptions, id: \.self) { option in
                            Text(appFilterLabel(option)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Picker("Session", selection: $selectedSessionFilter) {
                        ForEach(sessionFilterOptions, id: \.self) { option in
                            Text(sessionFilterLabel(option)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if historyStore.entries.isEmpty {
                emptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: "No requests yet",
                    subtitle: "Speech requests will appear here"
                )
            } else if filteredEntries.isEmpty {
                emptyState(
                    icon: "magnifyingglass",
                    title: "No matches",
                    subtitle: "Try adjusting your search or filters"
                )
            } else {
                List {
                    if !queueEntries.isEmpty {
                        Section {
                            ForEach(queueEntries) { entry in
                                entryRow(entry)
                            }
                        } header: {
                            Label("Queue", systemImage: "play.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Section {
                        ForEach(completedEntries) { entry in
                            entryRow(entry)
                        }
                    } header: {
                        Label("Completed", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .listStyle(.inset)
            }
        }
        .onChange(of: appFilterOptions) { options in
            if selectedAppFilter != Self.allAppsToken && !options.contains(selectedAppFilter) {
                selectedAppFilter = Self.allAppsToken
            }
        }
        .onChange(of: sessionFilterOptions) { options in
            if selectedSessionFilter != Self.allSessionsToken && !options.contains(selectedSessionFilter) {
                selectedSessionFilter = Self.allSessionsToken
            }
        }
    }

    private func normalizedAppName(_ sourceApp: String?) -> String {
        let trimmed = sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed! : "Unknown"
    }

    private func normalizedSessionId(_ sessionId: String?) -> String? {
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private func appFilterLabel(_ option: String) -> String {
        option == Self.allAppsToken ? "All apps" : option
    }

    private func sessionFilterLabel(_ option: String) -> String {
        if option == Self.allSessionsToken { return "All sessions" }
        if option == Self.noSessionToken { return "No session" }
        return String(option.prefix(12)) + (option.count > 12 ? "…" : "")
    }

    @ViewBuilder
    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.5))
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func entryRow(_ entry: RequestHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(normalizedAppName(entry.sourceApp))
                    .font(.subheadline)
                    .fontWeight(.medium)

                statusBadge(for: entry.status)

                Spacer()

                Text(Self.timestampFormatter.string(from: entry.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(entry.text)
                .font(.callout)
                .lineLimit(3)
                .foregroundColor(.primary.opacity(0.9))

            HStack(spacing: 8) {
                if let voice = entry.voice, !voice.isEmpty {
                    Label(voice, systemImage: "waveform")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let sessionId = normalizedSessionId(entry.sessionId) {
                    Label(String(sessionId.prefix(8)), systemImage: "number")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if entry.status == .interrupted {
                    Label("Stopped via ⌘.", systemImage: "stop.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(for status: RequestPlaybackStatus) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(status.tintColor)
                .frame(width: 6, height: 6)
            Text(status.displayName)
                .font(.caption2)
                .foregroundColor(status.tintColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(status.tintColor.opacity(0.12))
        .cornerRadius(4)
    }
}


struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                helpSection(title: "Using Loqui with Pi Agent", icon: "terminal") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How to use Loqui with the pi.dev agent:")
                            .font(.callout)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("1. Keep Loqui running in the menu bar.")
                            Text("2. Install the extension in Pi.")
                            Text("3. Ask Pi to respond normally — the extension routes <voice> content to Loqui.")
                            Text("4. Use Pi commands to control playback.")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)

                        CodeRow(code: "pi install npm:@swairshah/pi-talk", description: "Install extension")

                        VStack(alignment: .leading, spacing: 4) {
                            CodeRow(code: "/tts", description: "Toggle TTS on/off")
                            CodeRow(code: "/tts-mute", description: "Mute/unmute audio")
                            CodeRow(code: "/tts-say <text>", description: "Speak arbitrary text")
                            CodeRow(code: "/tts-stop", description: "Stop speech")
                            CodeRow(code: "/tts-status", description: "Check extension + server status")
                        }
                    }
                }

                helpSection(title: "CLI Usage", icon: "chevron.left.forwardslash.chevron.right") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use ptts in Terminal:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            CodeRow(code: "ptts \"Hello, world!\"", description: "Enqueue speech")
                            CodeRow(code: "ptts -v alba \"Hello\"", description: "Pick a voice")
                            CodeRow(code: "echo \"Hello\" | ptts", description: "Pipe input")
                            CodeRow(code: "ptts --stop", description: "Stop playback")
                        }
                    }
                }

                helpSection(title: "HTTP API", icon: "network") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Direct synthesis endpoint:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        CodeRow(code: "POST http://127.0.0.1:18080/stream", description: "Stream PCM audio")
                        CodeRow(code: "{\"text\":\"Hello\",\"voice\":\"fantine\"}", description: "JSON body")
                    }
                }

                helpSection(title: "Local Broker Queue", icon: "arrow.triangle.branch") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Centralized playback queue endpoint:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        CodeRow(code: "TCP 127.0.0.1:18081", description: "Connect via NDJSON")
                        CodeRow(code: "{\"type\":\"speak\",\"text\":\"Hi\"}", description: "Enqueue request")
                        CodeRow(code: "{\"type\":\"stop\"}", description: "Stop and clear queue")
                        CodeRow(code: "{\"type\":\"health\"}", description: "Check broker status")
                    }
                }

                Spacer(minLength: 8)
            }
            .padding()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private func helpSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.headline)
            }

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("We package the pocket-tts binary with the app, which runs a local server that lets any applications (including your coding agent - https://pi.dev!) be send text which Loqui says out loud. We ship a command line utility `ptts` so you can make any application talk via Loqui and we ship a pi extension so the pi agent gets a voice via Loqui.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Credits")
                        .font(.headline)
                    Text("Loqui is built on top of the PocketTTS ecosystem. Huge thanks to the original authors.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Pocket TTS")
                        .font(.headline)
                    Text("The original model by Kyutai Labs. Fast, compact, and high-quality local TTS.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Link("github.com/kyutai-labs/pocket-tts", destination: URL(string: "https://github.com/kyutai-labs/pocket-tts")!)
                        .font(.caption)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("pocket-tts (Rust implementation)")
                        .font(.headline)
                    Text("Native Rust implementation by babybirdprd used by Loqui under the hood.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Link("github.com/babybirdprd/pocket-tts", destination: URL(string: "https://github.com/babybirdprd/pocket-tts")!)
                        .font(.caption)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                )

                Spacer(minLength: 8)
            }
            .padding()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}


struct CodeRow: View {
    let code: String
    var description: String? = nil

    var body: some View {
        HStack {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)

            if let desc = description {
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy to clipboard")
        }
    }
}

struct KeyboardShortcutView: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .shadow(color: .black.opacity(0.1), radius: 0.5, y: 0.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.headline)
            }

            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}

struct VoiceButton: View {
    let name: String
    let isSelected: Bool
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
                Text(name.capitalized)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 1.5 : 1)
            )
            .foregroundColor(isSelected ? .accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}

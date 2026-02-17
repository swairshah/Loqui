import SwiftUI
import AppKit
import ServiceManagement
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let stopSpeech = Self("stopSpeech", default: .init(.period, modifiers: [.command, .shift]))
}

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
        stopServer()
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
        stopSpeechItem.keyEquivalentModifierMask = [.command, .shift]
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
    
    // MARK: - Global Shortcut
    
    func setupGlobalShortcut() {
        KeyboardShortcuts.onKeyUp(for: .stopSpeech) { [weak self] in
            self?.stopCurrentSpeech()
        }
    }
    
    @objc func stopCurrentSpeech() {
        // Kill any ffplay processes (the audio player)
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killTask.arguments = ["-9", "ffplay"]
        try? killTask.run()
        
        // Also send stop signal to server if it has that endpoint
        Task {
            do {
                var request = URLRequest(url: URL(string: "http://\(serverHost):\(serverPort)/stop")!)
                request.httpMethod = "POST"
                _ = try? await URLSession.shared.data(for: request)
            }
        }
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
        guard let binaryPath = getServerBinaryPath() else {
            showAlert(title: "Server Binary Not Found", 
                     message: "Could not find pocket-tts-cli. Please ensure it's installed or bundled with the app.")
            updateStatusIcon(running: false)
            return
        }
        
        // Set up bundled models in HF cache format
        setupBundledModelsCache()
        
        let process = Process()
        process.executableURL = binaryPath
        process.arguments = [
            "serve",
            "--port", String(serverPort),
            "--host", serverHost,
            "--voice", selectedVoice
        ]
        
        // Set up environment
        var env = ProcessInfo.processInfo.environment
        
        // Use app's cache directory for HuggingFace cache
        let cacheDir = getModelCachePath()
        env["HF_HOME"] = cacheDir.path
        
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
            window.title = "Loqui Settings"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 450, height: 420))
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

// MARK: - Settings View

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            HelpView()
                .tabItem {
                    Label("Help", systemImage: "questionmark.circle")
                }
        }
        .frame(width: 450, height: 400)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("ttsVoice") var voice = "fantine"
    @AppStorage("ttsPort") var port = 18080
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("showDockIcon") var showDockIcon = true
    @State private var isPreviewPlaying = false
    
    // All available voices from kyutai/pocket-tts
    let availableVoices = ["alba", "marius", "javert", "fantine", "cosette", "eponine", "azelma"]
    
    var body: some View {
        Form {
            // App header with icon
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    Text("Loqui")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Local Text-to-Speech")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            
            Section {
                Picker("Voice", selection: $voice) {
                    ForEach(availableVoices, id: \.self) { v in
                        Text(v.capitalized).tag(v)
                    }
                }
                .onChange(of: voice) { newVoice in
                    previewVoice(newVoice)
                }
            } header: {
                Text("Voice")
            }
            
            Section {
                HStack {
                    TextField("Port", value: $port, formatter: NumberFormatter())
                        .frame(width: 80)
                    Button("Apply") {
                        restartServerForSettingsChange()
                    }
                }
            } header: {
                Text("Server")
            }
            
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        setLaunchAtLogin(enabled: newValue)
                    }
                Toggle("Show Dock Icon", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _ in
                        updateDockIcon()
                    }
            } header: {
                Text("General")
            }
            
            Section {
                HStack {
                    Text("Stop Speech (Global)")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .stopSpeech)
                }
            } header: {
                Text("Shortcuts")
            }
        }
        .formStyle(.grouped)
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

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Getting Started")
                        .font(.headline)
                    Text("Loqui is a local text-to-speech server. Any application can send text to Loqui and have it spoken aloud.")
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                Group {
                    Text("CLI Usage")
                        .font(.headline)
                    Text("Use the `ptts` command in Terminal:")
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        codeRow("ptts \"Hello, world!\"")
                        codeRow("ptts -v alba \"Hello\"")
                        codeRow("echo \"Hello\" | ptts")
                        codeRow("ptts --stop")
                        codeRow("ptts --list-voices")
                    }
                }
                
                Divider()
                
                Group {
                    Text("HTTP API")
                        .font(.headline)
                    Text("POST to http://127.0.0.1:18080/stream")
                        .foregroundColor(.secondary)
                    
                    codeRow("{\"text\": \"Hello\", \"voice\": \"fantine\"}")
                }
                
                Divider()
                
                Group {
                    Text("Global Shortcut")
                        .font(.headline)
                    Text("Configure the Stop Speech shortcut in the General tab.")
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding()
        }
    }
    
    func codeRow(_ code: String) -> some View {
        Text(code)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)
    }
}

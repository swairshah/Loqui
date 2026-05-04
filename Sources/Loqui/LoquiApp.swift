import SwiftUI
import AppKit
import ServiceManagement
import Carbon.HIToolbox
import Network
import Darwin
import CoreAudio
import AVFoundation
import FluidAudio
import LoquiClient

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

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum MenuItemTag {
        static let status = 100
        static let dockIcon = 101
        static let serverEnabled = 102
        static let activeSessions = 200
        static let queue = 201
        static let history = 202
        static let activeApps = 203
    }

    private struct ActiveSessionSummary {
        let sourceApp: String
        let sessionId: String?
        let lastMessageAt: Date
        let queuedCount: Int
    }

    private struct ActiveAppSummary {
        let sourceApp: String
        let lastMessageAt: Date
        let totalCount: Int
        let queuedCount: Int
    }

    var statusItem: NSStatusItem!
    var isServerRunning = false
    var settingsWindow: NSWindow?
    var hotKeyRef: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var speechCoordinator: SpeechPlaybackCoordinator?
    var localBroker: LocalSpeechBroker?
    var micMonitor: MicrophoneActivityMonitor?
    private var ttsEngine: FluidPocketTTSEngine?
    let socketPath = LoquiSocketPaths.socketPath
    private var serverEnabledSwitch: NSSwitch?
    private var speechSpeedSlider: NSSlider?
    private var speechSpeedLabel: NSTextField?

    private let activeSessionWindow: TimeInterval = 5 * 60
    private let maxMenuRowsPerSection = 8
    private lazy var relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
    
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
    
    var serverEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "serverEnabled") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "serverEnabled")
        }
        set {
            setServerEnabled(newValue)
        }
    }

    var selectedVoice: String {
        UserDefaults.standard.string(forKey: "ttsVoice") ?? "fantine"
    }

    func setServerEnabled(_ enabled: Bool) {
        let oldValue = serverEnabled
        UserDefaults.standard.set(enabled, forKey: "serverEnabled")
        syncServerEnabledSwitchState()

        guard oldValue != enabled else { return }

        if enabled {
            startLocalBroker()
        } else {
            speechCoordinator?.stopAll()
            stopLocalBroker()
            updateStatusIcon(running: false)
        }
    }

    func syncServerEnabledSwitchState() {
        serverEnabledSwitch?.state = serverEnabled ? .on : .off
    }

    func syncSpeechSpeedControlState() {
        let speed = currentSpeechSpeed()
        speechSpeedSlider?.doubleValue = speed
        speechSpeedLabel?.stringValue = String(format: "%.1fx", speed)
    }

    private func stopLocalBroker() {
        localBroker?.stop()
        localBroker = nil
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupGlobalShortcut()
        updateDockIconVisibility()

        let engine = FluidPocketTTSEngine(modelDirectory: getModelCachePath(), defaultVoice: selectedVoice)
        ttsEngine = engine
        speechCoordinator = SpeechPlaybackCoordinator(
            engine: engine,
            defaultVoiceProvider: { [weak self] in self?.selectedVoice ?? "fantine" }
        )

        micMonitor = MicrophoneActivityMonitor { [weak self] isActive in
            self?.speechCoordinator?.setMicrophoneActive(isActive)
        }
        micMonitor?.start()

        syncServerEnabledSwitchState()
        if serverEnabled {
            startLocalBroker()
        } else {
            updateStatusIcon(running: false)
        }
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
        stopLocalBroker()
        speechCoordinator?.stopAll()
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
        menu.delegate = self

        let statusMenuItem = NSMenuItem(title: "Server: Starting...", action: nil, keyEquivalent: "")
        statusMenuItem.tag = MenuItemTag.status
        menu.addItem(statusMenuItem)

        menu.addItem(makePlaybackControlsMenuItem())
        menu.addItem(NSMenuItem.separator())

        let activeSessionsItem = NSMenuItem(title: "Active Sessions (0)", action: nil, keyEquivalent: "")
        activeSessionsItem.tag = MenuItemTag.activeSessions
        menu.addItem(activeSessionsItem)

        let activeAppsItem = NSMenuItem(title: "Active Apps (0)", action: nil, keyEquivalent: "")
        activeAppsItem.tag = MenuItemTag.activeApps
        menu.addItem(activeAppsItem)

        let queueItem = NSMenuItem(title: "Queue (0)", action: nil, keyEquivalent: "")
        queueItem.tag = MenuItemTag.queue
        menu.addItem(queueItem)

        let historyItem = NSMenuItem(title: "History (0)", action: nil, keyEquivalent: "")
        historyItem.tag = MenuItemTag.history
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        let stopSpeechItem = NSMenuItem(title: "Stop Speech", action: #selector(stopCurrentSpeech), keyEquivalent: ".")
        stopSpeechItem.keyEquivalentModifierMask = [.command]
        stopSpeechItem.target = self
        menu.addItem(stopSpeechItem)

        menu.addItem(NSMenuItem.separator())

        let restartItem = NSMenuItem(title: "Restart Server", action: #selector(restartServer), keyEquivalent: "r")
        restartItem.target = self
        menu.addItem(restartItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let dockIconItem = NSMenuItem(title: "Show Dock Icon", action: #selector(toggleDockIcon), keyEquivalent: "")
        dockIconItem.tag = MenuItemTag.dockIcon
        dockIconItem.state = showDockIcon ? .on : .off
        dockIconItem.target = self
        menu.addItem(dockIconItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Loqui", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshSessionSectionsMenu()
    }

    private func makePlaybackControlsMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = MenuItemTag.serverEnabled

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 38))

        let speedIcon = NSImageView(frame: NSRect(x: 12, y: 10, width: 20, height: 18))
        speedIcon.image = NSImage(systemSymbolName: "tortoise", accessibilityDescription: "Speech speed")
        speedIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        speedIcon.contentTintColor = .secondaryLabelColor
        container.addSubview(speedIcon)

        let slider = NSSlider(value: currentSpeechSpeed(), minValue: 0.7, maxValue: 2.0, target: self, action: #selector(speechSpeedSliderChanged(_:)))
        slider.frame = NSRect(x: 42, y: 8, width: 100, height: 22)
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.controlSize = .small
        container.addSubview(slider)

        let speedLabel = NSTextField(labelWithString: String(format: "%.1fx", currentSpeechSpeed()))
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        speedLabel.textColor = .secondaryLabelColor
        speedLabel.alignment = .right
        speedLabel.frame = NSRect(x: 148, y: 11, width: 44, height: 16)
        container.addSubview(speedLabel)

        let divider = NSBox(frame: NSRect(x: 207, y: 8, width: 1, height: 22))
        divider.boxType = .separator
        container.addSubview(divider)

        let speakerIcon = NSImageView(frame: NSRect(x: 222, y: 10, width: 20, height: 18))
        speakerIcon.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Server enabled")
        speakerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        speakerIcon.contentTintColor = .secondaryLabelColor
        container.addSubview(speakerIcon)

        let toggle = NSSwitch(frame: NSRect(x: 247, y: 7, width: 48, height: 24))
        toggle.target = self
        toggle.action = #selector(serverEnabledSwitchChanged(_:))
        toggle.state = serverEnabled ? .on : .off
        container.addSubview(toggle)

        speechSpeedSlider = slider
        speechSpeedLabel = speedLabel
        serverEnabledSwitch = toggle
        item.view = container
        return item
    }

    private func currentSpeechSpeed() -> Double {
        let raw = UserDefaults.standard.object(forKey: "speechSpeed") as? Double ?? 1.0
        let rounded = (raw * 20).rounded() / 20
        return min(2.0, max(0.7, rounded))
    }

    @objc private func speechSpeedSliderChanged(_ sender: NSSlider) {
        let speed = min(2.0, max(0.7, (sender.doubleValue * 20).rounded() / 20))
        UserDefaults.standard.set(speed, forKey: "speechSpeed")
        speechSpeedLabel?.stringValue = String(format: "%.1fx", speed)
    }

    @objc private func serverEnabledSwitchChanged(_ sender: NSSwitch) {
        setServerEnabled(sender.state == .on)
    }

    func menuWillOpen(_ menu: NSMenu) {
        syncServerEnabledSwitchState()
        syncSpeechSpeedControlState()
        refreshSessionSectionsMenu()
    }

    private func refreshSessionSectionsMenu() {
        guard let menu = statusItem.menu else { return }

        let entries = RequestHistoryStore.shared.entries
        let activeSessions = buildActiveSessions(from: entries)
        let activeApps = buildActiveApps(from: entries)
        let queueEntries = entries
            .filter { $0.status.isInQueue }
            .sorted { $0.timestamp < $1.timestamp }
        let historyEntries = entries
            .filter { !$0.status.isInQueue }
            .sorted { $0.timestamp > $1.timestamp }

        if let activeItem = menu.item(withTag: MenuItemTag.activeSessions) {
            activeItem.title = "Active Sessions (\(activeSessions.count))"
            activeItem.submenu = makeActiveSessionsSubmenu(activeSessions)
        }

        if let activeAppsItem = menu.item(withTag: MenuItemTag.activeApps) {
            activeAppsItem.title = "Active Apps (\(activeApps.count))"
            activeAppsItem.submenu = makeActiveAppsSubmenu(activeApps)
        }

        if let queueItem = menu.item(withTag: MenuItemTag.queue) {
            queueItem.title = "Queue (\(queueEntries.count))"
            queueItem.submenu = makeQueueSubmenu(queueEntries)
        }

        if let historyItem = menu.item(withTag: MenuItemTag.history) {
            historyItem.title = "History (\(historyEntries.count))"
            historyItem.submenu = makeHistorySubmenu(historyEntries)
        }
    }

    private func buildActiveSessions(from entries: [RequestHistoryEntry]) -> [ActiveSessionSummary] {
        let cutoff = Date().addingTimeInterval(-activeSessionWindow)
        var buckets: [String: ActiveSessionSummary] = [:]

        for entry in entries {
            let sourceApp = normalizedAppName(entry.sourceApp)
            let sessionId = normalizedSessionId(entry.sessionId)
            let key = "\(sourceApp)::\(sessionId ?? "__none__")"
            let queuedIncrement = entry.status.isInQueue ? 1 : 0

            if let existing = buckets[key] {
                buckets[key] = ActiveSessionSummary(
                    sourceApp: existing.sourceApp,
                    sessionId: existing.sessionId,
                    lastMessageAt: max(existing.lastMessageAt, entry.timestamp),
                    queuedCount: existing.queuedCount + queuedIncrement
                )
            } else {
                buckets[key] = ActiveSessionSummary(
                    sourceApp: sourceApp,
                    sessionId: sessionId,
                    lastMessageAt: entry.timestamp,
                    queuedCount: queuedIncrement
                )
            }
        }

        return buckets.values
            .filter { $0.lastMessageAt >= cutoff }
            .sorted { $0.lastMessageAt > $1.lastMessageAt }
    }

    private func buildActiveApps(from entries: [RequestHistoryEntry]) -> [ActiveAppSummary] {
        let cutoff = Date().addingTimeInterval(-activeSessionWindow)
        var buckets: [String: ActiveAppSummary] = [:]

        for entry in entries where entry.timestamp >= cutoff {
            let sourceApp = normalizedAppName(entry.sourceApp)
            let queuedIncrement = entry.status.isInQueue ? 1 : 0

            if let existing = buckets[sourceApp] {
                buckets[sourceApp] = ActiveAppSummary(
                    sourceApp: existing.sourceApp,
                    lastMessageAt: max(existing.lastMessageAt, entry.timestamp),
                    totalCount: existing.totalCount + 1,
                    queuedCount: existing.queuedCount + queuedIncrement
                )
            } else {
                buckets[sourceApp] = ActiveAppSummary(
                    sourceApp: sourceApp,
                    lastMessageAt: entry.timestamp,
                    totalCount: 1,
                    queuedCount: queuedIncrement
                )
            }
        }

        return buckets.values.sorted { $0.lastMessageAt > $1.lastMessageAt }
    }

    private func makeActiveSessionsSubmenu(_ sessions: [ActiveSessionSummary]) -> NSMenu {
        let submenu = NSMenu()

        guard !sessions.isEmpty else {
            submenu.addItem(makeDisabledMenuItem("No active sessions in the last 5m"))
            return submenu
        }

        for session in sessions.prefix(maxMenuRowsPerSection) {
            let relative = relativeDateFormatter.localizedString(for: session.lastMessageAt, relativeTo: Date())
            let sessionLabel = shortSessionLabel(session.sessionId) ?? "No session"
            var title = "\(session.sourceApp) [\(sessionLabel)] • \(relative)"
            if session.queuedCount > 0 {
                title += " • \(session.queuedCount) queued"
            }
            submenu.addItem(makeDisabledMenuItem(title))
        }

        if sessions.count > maxMenuRowsPerSection {
            submenu.addItem(makeDisabledMenuItem("… \(sessions.count - maxMenuRowsPerSection) more"))
        }

        return submenu
    }

    private func makeActiveAppsSubmenu(_ apps: [ActiveAppSummary]) -> NSMenu {
        let submenu = NSMenu()

        guard !apps.isEmpty else {
            submenu.addItem(makeDisabledMenuItem("No active apps in the last 5m"))
            return submenu
        }

        for app in apps.prefix(maxMenuRowsPerSection) {
            let relative = relativeDateFormatter.localizedString(for: app.lastMessageAt, relativeTo: Date())
            var title = "\(app.sourceApp) • \(app.totalCount) request\(app.totalCount == 1 ? "" : "s") • \(relative)"
            if app.queuedCount > 0 {
                title += " • \(app.queuedCount) queued"
            }
            submenu.addItem(makeDisabledMenuItem(title))
        }

        if apps.count > maxMenuRowsPerSection {
            submenu.addItem(makeDisabledMenuItem("… \(apps.count - maxMenuRowsPerSection) more"))
        }

        submenu.addItem(NSMenuItem.separator())
        let openHistoryItem = NSMenuItem(title: "Open History…", action: #selector(openSettings), keyEquivalent: "")
        openHistoryItem.target = self
        submenu.addItem(openHistoryItem)

        return submenu
    }

    private func makeQueueSubmenu(_ entries: [RequestHistoryEntry]) -> NSMenu {
        let submenu = NSMenu()

        guard !entries.isEmpty else {
            submenu.addItem(makeDisabledMenuItem("Queue is clear"))
            return submenu
        }

        for entry in entries.prefix(maxMenuRowsPerSection) {
            let app = normalizedAppName(entry.sourceApp)
            let text = trimmedSnippet(entry.text)
            let relative = relativeDateFormatter.localizedString(for: entry.timestamp, relativeTo: Date())

            if let session = shortSessionLabel(entry.sessionId) {
                submenu.addItem(makeDisabledMenuItem("\(app) [\(session)] • \(text) • \(relative)"))
            } else {
                submenu.addItem(makeDisabledMenuItem("\(app) • \(text) • \(relative)"))
            }
        }

        if entries.count > maxMenuRowsPerSection {
            submenu.addItem(makeDisabledMenuItem("… \(entries.count - maxMenuRowsPerSection) more"))
        }

        return submenu
    }

    private func makeHistorySubmenu(_ entries: [RequestHistoryEntry]) -> NSMenu {
        let submenu = NSMenu()

        guard !entries.isEmpty else {
            submenu.addItem(makeDisabledMenuItem("No history yet"))
            return submenu
        }

        for entry in entries.prefix(maxMenuRowsPerSection) {
            let status = entry.status.displayName
            let text = trimmedSnippet(entry.text)
            let relative = relativeDateFormatter.localizedString(for: entry.timestamp, relativeTo: Date())
            submenu.addItem(makeDisabledMenuItem("[\(status)] \(text) • \(relative)"))
        }

        if entries.count > maxMenuRowsPerSection {
            submenu.addItem(makeDisabledMenuItem("… \(entries.count - maxMenuRowsPerSection) more"))
        }

        submenu.addItem(NSMenuItem.separator())
        let openHistoryItem = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: "")
        openHistoryItem.target = self
        submenu.addItem(openHistoryItem)

        return submenu
    }

    private func makeDisabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func normalizedAppName(_ sourceApp: String?) -> String {
        let trimmed = sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed! : "Unknown"
    }

    private func normalizedSessionId(_ sessionId: String?) -> String? {
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private func shortSessionLabel(_ sessionId: String?) -> String? {
        guard let sessionId = normalizedSessionId(sessionId) else { return nil }
        let suffix = sessionId.count > 12 ? "…" : ""
        return String(sessionId.prefix(12)) + suffix
    }

    private func trimmedSnippet(_ text: String, maxLength: Int = 50) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsed.count > maxLength else {
            return collapsed
        }

        return String(collapsed.prefix(maxLength)) + "…"
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
           let statusItem = menu.item(withTag: MenuItemTag.status) {
            if !serverEnabled {
                statusItem.title = "Server: Disabled"
            } else {
                statusItem.title = running ? "Server: Running on Unix sockets" : "Server: Stopped"
            }
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
        guard serverEnabled else { return }
        guard localBroker == nil else { return }
        guard let coordinator = speechCoordinator else { return }
        guard let engine = ttsEngine else { return }
        do {
            let broker = try LocalSpeechBroker(
                socketPath: socketPath,
                engine: engine,
                coordinator: coordinator,
                defaultVoiceProvider: { [weak self] in self?.selectedVoice ?? "fantine" }
            )
            broker.start()
            localBroker = broker
            print("Loqui: Local API listening on \(socketPath)")
            checkServerHealth()
        } catch {
            print("Loqui: Failed to start local API: \(error)")
        }
    }
    
    @objc func stopCurrentSpeech() {
        // Centralized stop: clear broker queue, stop active Loqui playback, stop current synth request.
        speechCoordinator?.stopAll()
    }
    
    // MARK: - Server Management
    
    func getModelCachePath() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let pocketTTSDir = appSupport.appendingPathComponent("Loqui").appendingPathComponent("FluidAudio")
        try? FileManager.default.createDirectory(at: pocketTTSDir, withIntermediateDirectories: true)
        return pocketTTSDir
    }
    
    func startServer() {
        guard serverEnabled else {
            updateStatusIcon(running: false)
            return
        }

        startLocalBroker()
    }
    
    func checkServerHealth() {
        guard serverEnabled else { return }

        Task {
            do {
                let healthy = try await TTSClient(socketPath: socketPath).healthCheck()

                if healthy {
                    await MainActor.run {
                        updateStatusIcon(running: true)
                    }
                } else {
                    // Retry after a delay
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if serverEnabled {
                        checkServerHealth()
                    }
                }
            } catch {
                // Server not ready yet, retry
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if serverEnabled, localBroker != nil {
                    checkServerHealth()
                }
            }
        }
    }
    
    func stopServer() {
        stopLocalBroker()
        updateStatusIcon(running: false)
    }
    
    @objc func restartServer() {
        stopServer()
        guard serverEnabled else {
            stopLocalBroker()
            return
        }

        startLocalBroker()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startServer()
        }
    }
    
    @objc func toggleDockIcon() {
        showDockIcon = !showDockIcon
        // Update menu item state
        if let menu = statusItem.menu, let item = menu.item(withTag: MenuItemTag.dockIcon) {
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
    let voices: [String]?
    let audioBase64: String?
    let contentType: String?

    static func success(
        queued: Int? = nil,
        pending: Int? = nil,
        playing: Bool? = nil,
        currentQueue: String? = nil,
        voices: [String]? = nil,
        audioBase64: String? = nil,
        contentType: String? = nil
    ) -> BrokerResponse {
        BrokerResponse(
            ok: true,
            error: nil,
            queued: queued,
            pending: pending,
            playing: playing,
            currentQueue: currentQueue,
            voices: voices,
            audioBase64: audioBase64,
            contentType: contentType
        )
    }

    static func failure(_ message: String) -> BrokerResponse {
        BrokerResponse(
            ok: false,
            error: message,
            queued: nil,
            pending: nil,
            playing: nil,
            currentQueue: nil,
            voices: nil,
            audioBase64: nil,
            contentType: nil
        )
    }
}

private enum UnixSocketListener {
    static func make(path: String) throws -> NWListener {
        try LoquiSocketPaths.prepareDirectory()
        try? FileManager.default.removeItem(atPath: path)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        return try NWListener(using: parameters)
    }

    static func cleanup(path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

actor FluidPocketTTSEngine {
    private let manager: PocketTtsManager
    private var initialized = false

    init(modelDirectory: URL, defaultVoice: String) {
        manager = PocketTtsManager(
            defaultVoice: defaultVoice,
            language: .english,
            directory: modelDirectory
        )
    }

    func synthesizeWav(text: String, voice: String?) async throws -> Data {
        if !initialized {
            try await manager.initialize()
            initialized = true
        }

        let trimmedVoice = voice?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await manager.synthesize(
            text: text,
            voice: trimmedVoice?.isEmpty == false ? trimmedVoice : nil
        )
    }

    func synthesizePCMStream(text: String, voice: String?) async throws -> AsyncThrowingStream<[Float], Error> {
        if !initialized {
            try await manager.initialize()
            initialized = true
        }

        let trimmedVoice = voice?.trimmingCharacters(in: .whitespacesAndNewlines)
        let frameStream = try await manager.synthesizeStreaming(
            text: text,
            voice: trimmedVoice?.isEmpty == false ? trimmedVoice : nil
        )

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await frame in frameStream {
                        continuation.yield(frame.samples)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

final class NativeStreamingAudioPlayback: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format: AVAudioFormat
    private let stateQueue = DispatchQueue(label: "loqui.native.audio.playback")

    private var pendingBuffers = 0
    private var finishedScheduling = false
    private var stopped = false
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(sampleRate: Double = 24_000, playbackRate: Double = 1.0) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "Loqui", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"])
        }

        self.format = format
        timePitch.rate = Float(min(2.0, max(0.7, playbackRate)))
    }

    var isRunning: Bool {
        stateQueue.sync { !stopped }
    }

    func start() throws {
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.play()
    }

    func schedule(samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw NSError(domain: "Loqui", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else {
            throw NSError(domain: "Loqui", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to access audio buffer"])
        }
        samples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                channel.update(from: baseAddress, count: samples.count)
            }
        }

        let shouldSchedule = stateQueue.sync { () -> Bool in
            guard !stopped else { return false }
            pendingBuffers += 1
            return true
        }
        guard shouldSchedule else { return }

        player.scheduleBuffer(buffer) { [weak self] in
            self?.bufferDidFinish()
        }

        if !player.isPlaying {
            player.play()
        }
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            stateQueue.async {
                self.finishedScheduling = true
                self.finishContinuation = continuation
                self.completeIfDoneLocked()
            }
        }
    }

    func stop() {
        stateQueue.sync {
            guard !stopped else { return }
            stopped = true
            finishContinuation?.resume()
            finishContinuation = nil
        }

        player.stop()
        engine.stop()
    }

    private func bufferDidFinish() {
        stateQueue.async {
            if self.pendingBuffers > 0 {
                self.pendingBuffers -= 1
            }
            self.completeIfDoneLocked()
        }
    }

    private func completeIfDoneLocked() {
        guard finishedScheduling, pendingBuffers == 0 else { return }
        stopped = true
        finishContinuation?.resume()
        finishContinuation = nil

        DispatchQueue.global().async { [player, engine] in
            player.stop()
            engine.stop()
        }
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
    private var currentPlayback: NativeStreamingAudioPlayback?
    private var currentJobHistoryId: UUID?
    private var currentQueueKey: String?
    private var currentRunNonce: UUID?

    private var isMicrophoneActive = false

    // Auto voice assignment for queues that don't specify voice.
    // Note: `alba` is intentionally excluded from auto-rotation.
    private let autoVoicePool = ["fantine", "cosette", "marius", "azelma"]
    private var autoVoiceByQueueKey: [String: String] = [:]
    private var autoVoiceCycleIndex = 0

    private let engine: FluidPocketTTSEngine
    private let defaultVoiceProvider: () -> String

    init(engine: FluidPocketTTSEngine,
         defaultVoiceProvider: @escaping () -> String) {
        self.engine = engine
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

    func stopAll(cancelActiveSynthesis: Bool = true) {
        let state = queue.sync { () -> (pending: [UUID], active: UUID?) in
            let pendingIds = allPendingHistoryIdsLocked()
            let activeId = currentJobHistoryId

            queuesByKey.removeAll()
            queueOrder.removeAll()
            // Keep voice assignments so continued sessions retain their prior auto-voice.
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

        if cancelActiveSynthesis {
            Task {
                await sendStopToServer()
            }
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
            let activelyPlaying = currentPlayback?.isRunning == true

            // Requirement: if mic starts while voice is already playing, cancel all queued work at that moment.
            guard activelyPlaying else { return }

            let pendingIds = allPendingHistoryIdsLocked()
            let activeId = currentJobHistoryId

            queuesByKey.removeAll()
            queueOrder.removeAll()
            // Keep voice assignments so this queue key keeps the same voice after interruption.
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
            guard await waitUntilMicrophoneInactive(runNonce: runNonce) else {
                return
            }
            guard shouldContinue(runNonce: runNonce) else {
                return
            }

            try await playStreaming(job: job, runNonce: runNonce)
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

            self.currentPlayback = nil
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

    private func playStreaming(job: SpeechJob, runNonce: UUID) async throws {
        let stream = try await engine.synthesizePCMStream(text: job.text, voice: job.voice)
        let playback = try NativeStreamingAudioPlayback(playbackRate: configuredSpeechSpeed())
        try playback.start()

        let accepted = queue.sync { () -> Bool in
            guard self.currentRunNonce == runNonce else { return false }
            self.currentPlayback = playback
            return true
        }
        guard accepted else {
            playback.stop()
            return
        }

        for try await samples in stream {
            guard shouldContinue(runNonce: runNonce) else {
                playback.stop()
                return
            }
            try playback.schedule(samples: samples)
        }

        await playback.finish()
    }

    private func configuredSpeechSpeed() -> Double {
        let raw = UserDefaults.standard.object(forKey: "speechSpeed") as? Double ?? 1.0
        let rounded = (raw * 100).rounded() / 100
        return min(2.0, max(0.7, rounded))
    }

    private func localPlaybackTempoFilter() -> String? {
        let speed = configuredSpeechSpeed()
        guard abs(speed - 1.0) > 0.01 else { return nil }
        return String(format: "atempo=%.2f", speed)
    }

    private func terminateCurrentProcessLocked() {
        currentPlayback?.stop()
        currentPlayback = nil
    }

    private func sendStopToServer() async {
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
    private let socketPath: String
    private let queue = DispatchQueue(label: "loqui.local.broker")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let coordinator: SpeechPlaybackCoordinator
    private let engine: FluidPocketTTSEngine
    private let defaultVoiceProvider: () -> String
    private let activeTasksLock = NSLock()
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    init(
        socketPath: String,
        engine: FluidPocketTTSEngine,
        coordinator: SpeechPlaybackCoordinator,
        defaultVoiceProvider: @escaping () -> String
    ) throws {
        self.socketPath = socketPath
        self.listener = try UnixSocketListener.make(path: socketPath)
        self.coordinator = coordinator
        self.defaultVoiceProvider = defaultVoiceProvider
        self.engine = engine
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
        stopActiveRequests()
        listener.cancel()
        UnixSocketListener.cleanup(path: socketPath)
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

        case "voices":
            send(response: .success(voices: TTSClient.availableVoices), on: connection)

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

        case "raw":
            synthesize(request: request, response: .rawPCM, on: connection)

        case "generate":
            synthesize(request: request, response: .wav, on: connection)

        case "stop":
            stopActiveRequests()
            coordinator.stopAll(cancelActiveSynthesis: false)
            let state = coordinator.state()
            send(response: .success(pending: state.pending, playing: state.playing, currentQueue: state.currentQueue), on: connection)

        default:
            send(response: .failure("Unknown command: \(request.type)"), on: connection)
        }
    }

    private enum SynthesisResponse {
        case rawPCM
        case wav
    }

    private func synthesize(request: BrokerRequest, response: SynthesisResponse, on connection: NWConnection) {
        guard let text = request.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            send(response: .failure("Missing text"), on: connection)
            return
        }

        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.removeActiveTask(taskID) }

            do {
                let wavData = try await self.engine.synthesizeWav(
                    text: text,
                    voice: request.voice ?? self.defaultVoiceProvider()
                )
                guard !Task.isCancelled else {
                    connection.cancel()
                    return
                }

                switch response {
                case .rawPCM:
                    let pcmData = try Self.extractPCMData(fromWav: wavData)
                    self.send(
                        response: .success(
                            audioBase64: pcmData.base64EncodedString(),
                            contentType: "audio/L16; rate=24000; channels=1"
                        ),
                        on: connection
                    )
                case .wav:
                    self.send(
                        response: .success(
                            audioBase64: wavData.base64EncodedString(),
                            contentType: "audio/wav"
                        ),
                        on: connection
                    )
                }
            } catch {
                guard !Task.isCancelled else {
                    connection.cancel()
                    return
                }
                self.send(response: .failure(error.localizedDescription), on: connection)
            }
        }

        activeTasksLock.lock()
        activeTasks[taskID] = task
        activeTasksLock.unlock()
    }

    private func stopActiveRequests() {
        activeTasksLock.lock()
        let tasks = activeTasks.values
        activeTasks.removeAll()
        activeTasksLock.unlock()

        for task in tasks {
            task.cancel()
        }
    }

    private func removeActiveTask(_ taskID: UUID) {
        activeTasksLock.lock()
        activeTasks.removeValue(forKey: taskID)
        activeTasksLock.unlock()
    }

    private static func extractPCMData(fromWav wavData: Data) throws -> Data {
        guard wavData.count >= 12,
              String(data: wavData.subdata(in: 0..<4), encoding: .ascii) == "RIFF",
              String(data: wavData.subdata(in: 8..<12), encoding: .ascii) == "WAVE"
        else {
            throw NSError(domain: "Loqui", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid WAV response from FluidAudio"])
        }

        var offset = 12
        while offset + 8 <= wavData.count {
            let chunkID = String(data: wavData.subdata(in: offset..<(offset + 4)), encoding: .ascii)
            let chunkSize = wavData.withUnsafeBytes { rawBuffer -> UInt32 in
                let base = rawBuffer.baseAddress!.advanced(by: offset + 4)
                return base.loadUnaligned(as: UInt32.self).littleEndian
            }
            let dataStart = offset + 8
            let dataEnd = dataStart + Int(chunkSize)

            guard dataEnd <= wavData.count else { break }
            if chunkID == "data" {
                return wavData.subdata(in: dataStart..<dataEnd)
            }

            offset = dataEnd + (Int(chunkSize) % 2)
        }

        throw NSError(domain: "Loqui", code: 3, userInfo: [NSLocalizedDescriptionKey: "WAV data chunk not found"])
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

        sendPayload(payload, on: connection)
    }

    private func sendPayload(_ payload: Data, on connection: NWConnection, offset: Int = 0) {
        let chunkSize = 16 * 1024
        guard offset < payload.count else {
            return
        }

        let end = min(offset + chunkSize, payload.count)
        let isFinal = end == payload.count
        connection.send(
            content: payload.subdata(in: offset..<end),
            contentContext: .defaultMessage,
            isComplete: isFinal,
            completion: .contentProcessed { [weak self] _ in
                if !isFinal {
                    self?.sendPayload(payload, on: connection, offset: end)
                }
            }
        )
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
    @AppStorage("speechSpeed") var speechSpeed = 1.0
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("showDockIcon") var showDockIcon = true
    @AppStorage("serverEnabled") var serverEnabled = true
    @State private var isPreviewPlaying = false
    
    // All available voices from kyutai/pocket-tts
    let availableVoices = ["alba", "marius", "javert", "fantine", "cosette", "eponine", "azelma", "vera", "charles", "paul", "caro_davy", "peter_yearsley", "stuart_bell"]
    
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
                    .disabled(isPreviewPlaying || !serverEnabled)
                }
            }

            Section("Playback") {
                HStack(spacing: 10) {
                    Image(systemName: "tortoise")
                        .foregroundStyle(.secondary)

                    Slider(value: $speechSpeed, in: 0.7...2.0, step: 0.05)

                    Image(systemName: "hare")
                        .foregroundStyle(.secondary)

                    Text(String(format: "%.1fx", clampedSpeechSpeed))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .help("Speech speed: \(String(format: "%.2f", clampedSpeechSpeed))x")

                Button("Reset Speed") {
                    speechSpeed = 1.0
                }
                .disabled(abs(clampedSpeechSpeed - 1.0) < 0.01)
            }

            Section("Server") {
                Toggle("Enable Server", isOn: $serverEnabled)
                    .onChange(of: serverEnabled) {
                        updateServerEnabled()
                    }

                HStack {
                    Text("API")
                    Spacer()
                    Text("Unix sockets")
                        .foregroundColor(.secondary)
                }
            }

            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        setLaunchAtLogin(enabled: launchAtLogin)
                    }

                Toggle("Show Dock Icon", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) {
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
    }

    private var clampedSpeechSpeed: Double {
        min(2.0, max(0.7, speechSpeed))
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
    
    func updateServerEnabled() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.setServerEnabled(serverEnabled)
        }
    }

    func previewVoice(_ voiceName: String) {
        guard !isPreviewPlaying else { return }
        isPreviewPlaying = true
        
        let text = "Hi, this is \(voiceName.capitalized)."
        let playbackRate = clampedSpeechSpeed
        
        Task {
            do {
                let data = try await TTSClient().synthesize(text: text, voice: voiceName)
                let playback = try NativeStreamingAudioPlayback(playbackRate: playbackRate)
                try playback.start()
                try playback.schedule(samples: Self.floatSamples(fromPCM16LE: data))
                await playback.finish()
                await MainActor.run {
                    self.isPreviewPlaying = false
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

    private static func floatSamples(fromPCM16LE data: Data) -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(data.count / 2)

        var offset = 0
        while offset + 1 < data.count {
            let low = UInt16(data[offset])
            let high = UInt16(data[offset + 1]) << 8
            let sample = Int16(bitPattern: low | high)
            samples.append(max(-1.0, Float(sample) / Float(Int16.max)))
            offset += 2
        }

        return samples
    }
}

struct HistoryView: View {
    @StateObject private var historyStore = RequestHistoryStore.shared
    @State private var searchText = ""
    @State private var selectedAppFilter = Self.allAppsToken
    @State private var selectedSessionFilter = Self.allSessionsToken
    @State private var derivedState = DerivedState.empty

    private static let allAppsToken = "__all_apps__"
    private static let allSessionsToken = "__all_sessions__"
    private static let noSessionToken = "__no_session__"

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private struct DerivedState {
        let totalEntryCount: Int
        let appFilterOptions: [String]
        let sessionFilterOptions: [String]
        let isFiltering: Bool
        let filteredEntries: [RequestHistoryEntry]
        let queueEntries: [RequestHistoryEntry]
        let completedEntries: [RequestHistoryEntry]

        static let empty = DerivedState(
            totalEntryCount: 0,
            appFilterOptions: [HistoryView.allAppsToken],
            sessionFilterOptions: [HistoryView.allSessionsToken],
            isFiltering: false,
            filteredEntries: [],
            queueEntries: [],
            completedEntries: []
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("History")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("\(derivedState.queueEntries.count) queued · \(derivedState.completedEntries.count) completed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if derivedState.isFiltering {
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
                    .disabled(derivedState.totalEntryCount == 0)
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
                        ForEach(derivedState.appFilterOptions, id: \.self) { option in
                            Text(appFilterLabel(option)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Picker("Session", selection: $selectedSessionFilter) {
                        ForEach(derivedState.sessionFilterOptions, id: \.self) { option in
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

            if derivedState.totalEntryCount == 0 {
                emptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: "No requests yet",
                    subtitle: "Speech requests will appear here"
                )
            } else if derivedState.filteredEntries.isEmpty {
                emptyState(
                    icon: "magnifyingglass",
                    title: "No matches",
                    subtitle: "Try adjusting your search or filters"
                )
            } else {
                List {
                    if !derivedState.queueEntries.isEmpty {
                        Section {
                            ForEach(derivedState.queueEntries) { entry in
                                entryRow(entry)
                            }
                        } header: {
                            Label("Queue", systemImage: "play.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Section {
                        ForEach(derivedState.completedEntries) { entry in
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
        .onAppear { recomputeDerivedState() }
        .onReceive(historyStore.$entries) { _ in recomputeDerivedState() }
        .onChange(of: searchText) { recomputeDerivedState() }
        .onChange(of: selectedAppFilter) { recomputeDerivedState() }
        .onChange(of: selectedSessionFilter) { recomputeDerivedState() }
    }

    private func recomputeDerivedState() {
        let entries = historyStore.entries

        let appOptions = [Self.allAppsToken] + Set(entries.map { normalizedAppName($0.sourceApp) }).sorted()

        var sessionOptions = [Self.allSessionsToken]
        if entries.contains(where: { normalizedSessionId($0.sessionId) == nil }) {
            sessionOptions.append(Self.noSessionToken)
        }
        sessionOptions.append(contentsOf: Set(entries.compactMap { normalizedSessionId($0.sessionId) }).sorted())

        var resolvedAppFilter = selectedAppFilter
        var resolvedSessionFilter = selectedSessionFilter

        if resolvedAppFilter != Self.allAppsToken && !appOptions.contains(resolvedAppFilter) {
            resolvedAppFilter = Self.allAppsToken
        }
        if resolvedSessionFilter != Self.allSessionsToken && !sessionOptions.contains(resolvedSessionFilter) {
            resolvedSessionFilter = Self.allSessionsToken
        }

        let searchLower = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let filteredEntries = entries.filter { entry in
            if !searchLower.isEmpty {
                let textMatches = entry.text.lowercased().contains(searchLower)
                let appMatches = normalizedAppName(entry.sourceApp).lowercased().contains(searchLower)
                let sessionMatches = (entry.sessionId?.lowercased().contains(searchLower) ?? false)
                if !textMatches && !appMatches && !sessionMatches {
                    return false
                }
            }

            if resolvedAppFilter != Self.allAppsToken,
               normalizedAppName(entry.sourceApp) != resolvedAppFilter {
                return false
            }

            if resolvedSessionFilter == Self.noSessionToken {
                return normalizedSessionId(entry.sessionId) == nil
            }

            if resolvedSessionFilter != Self.allSessionsToken,
               normalizedSessionId(entry.sessionId) != resolvedSessionFilter {
                return false
            }

            return true
        }

        let queueEntries = filteredEntries
            .filter { $0.status.isInQueue }
            .sorted { $0.timestamp < $1.timestamp }
        let completedEntries = filteredEntries.filter { !$0.status.isInQueue }
        let isFiltering = !searchLower.isEmpty || resolvedAppFilter != Self.allAppsToken || resolvedSessionFilter != Self.allSessionsToken

        derivedState = DerivedState(
            totalEntryCount: entries.count,
            appFilterOptions: appOptions,
            sessionFilterOptions: sessionOptions,
            isFiltering: isFiltering,
            filteredEntries: filteredEntries,
            queueEntries: queueEntries,
            completedEntries: completedEntries
        )

        if selectedAppFilter != resolvedAppFilter {
            selectedAppFilter = resolvedAppFilter
        }
        if selectedSessionFilter != resolvedSessionFilter {
            selectedSessionFilter = resolvedSessionFilter
        }
    }

    private func normalizedAppName(_ sourceApp: String?) -> String {
        let trimmed = sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed! : "Unknown"
    }

    private func normalizedSessionId(_ sessionId: String?) -> String? {
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = trimmed, !value.isEmpty else { return nil }
        if UUID(uuidString: value) != nil { return nil }
        let hexDash = value.filter { $0.isHexDigit || $0 == "-" }
        if hexDash.count > value.count / 2 && value.count > 8 { return nil }
        return value
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
                        Text("Use loqui in Terminal:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            CodeRow(code: "loqui say \"Hello, world!\"", description: "Enqueue speech")
                            CodeRow(code: "loqui say -v alba \"Hello\"", description: "Pick a voice")
                            CodeRow(code: "echo \"Hello\" | loqui say", description: "Pipe input")
                            CodeRow(code: "loqui stop", description: "Stop playback")
                        }
                    }
                }

                helpSection(title: "Local API", icon: "network") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Unified local socket:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        CodeRow(code: "~/Library/Application Support/Loqui/loqui.sock", description: "Connect via NDJSON")
                        CodeRow(code: "{\"type\":\"raw\",\"text\":\"Hi\"}", description: "Raw PCM request")
                    }
                }

                helpSection(title: "Local Broker Queue", icon: "arrow.triangle.branch") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Centralized playback queue command:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        CodeRow(code: "{\"type\":\"speak\",\"text\":\"Hi\"}", description: "Enqueue request")
                        CodeRow(code: "{\"type\":\"stop\"}", description: "Stop and clear queue")
                        CodeRow(code: "{\"type\":\"health\"}", description: "Check status")
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
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    Text("Loqui")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("Local voice for any Mac app")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 8) {
                    Text("About")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Loqui is a macOS menu bar voice server. It runs local PocketTTS synthesis through FluidAudio and exposes Unix socket APIs so command-line tools, coding agents, and custom scripts can speak through one shared app.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Included Tools")
                        .font(.headline)
                    Text("Use `loqui` from Terminal, connect to the local socket API, or install the bundled Pi extension for spoken <voice> responses.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    CodeRow(code: "loqui say \"Hello from Loqui\"", description: "Speak from Terminal")
                    CodeRow(code: "pi install npm:@swairshah/pi-talk", description: "Voice routing for Pi")
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("Credits")
                        .font(.headline)
                    Text("Loqui builds on Kyutai Labs’ PocketTTS model and Fluid Inference’s native Swift/CoreML FluidAudio runtime.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Link("github.com/kyutai-labs/pocket-tts", destination: URL(string: "https://github.com/kyutai-labs/pocket-tts")!)
                        .font(.caption)
                    Link("github.com/FluidInference/FluidAudio", destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
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
                    Text("Project Repository")
                        .font(.headline)
                    Text("Loqui is maintained at the repository below. Open issues there for bugs, installation problems, or feature requests.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Link("github.com/swairshah/Loqui", destination: URL(string: "https://github.com/swairshah/Loqui")!)
                        .font(.caption)
                    Link("github.com/swairshah/Loqui/issues", destination: URL(string: "https://github.com/swairshah/Loqui/issues")!)
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

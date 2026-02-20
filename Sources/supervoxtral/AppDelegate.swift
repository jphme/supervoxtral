import AppKit
import HotKey

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var stateDetailItem: NSMenuItem!
    private var hotkeyDetailItem: NSMenuItem!

    private var hotKey: HotKey?
    private var rightCommandMonitor: RightCommandMonitor?
    private var statusWatchdog: Timer?

    private var settings: AppSettings!
    private var settingsPath: URL!
    private var settingsLastModified: Date?
    private var controller: DictationController!
    private var currentState: ControllerState = .loading
    private var menuBarHealthy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let loaded = SettingsLoader.load()
        settings = loaded.0
        settingsPath = loaded.1
        settingsLastModified = fileModificationDate(for: settingsPath)

        setupMenuBar()
        startStatusWatchdog()
        setupController()
        registerHotkey()
        updateState(.loading)

        Task {
            let granted = await PermissionManager.requestMicrophoneAccess()
            log("Microphone permission granted: \(granted)")
        }

        controller.start()
        log("Settings file: \(settingsPath.path)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusWatchdog?.invalidate()
        statusWatchdog = nil
        rightCommandMonitor?.stop()
    }

    private func setupController() {
        controller = DictationController(settings: settings)

        controller.onStateChange = { [weak self] state in
            self?.updateState(state)
        }

        controller.onTranscript = { _ in
            // Typed output appears at cursor.
        }

        controller.onStatusDetail = { [weak self] detail in
            self?.stateDetailItem.title = "Status: \(detail)"
        }

        controller.onError = { [weak self] message in
            self?.stateDetailItem.title = "Status: \(message)"
            self?.log(message)
        }
    }

    private func setupMenuBar(forceReinstall: Bool = false) {
        if forceReinstall, let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
            statusItem = nil
        }
        if statusItem != nil, statusItem.button != nil {
            menuBarHealthy = true
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true

        guard let button = statusItem.button else {
            menuBarHealthy = false
            NSApplication.shared.setActivationPolicy(.regular)
            return
        }

        button.title = ""
        button.image = image(for: .loading)
        button.imagePosition = .imageOnly
        button.appearsDisabled = false

        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Start Dictation", action: #selector(toggleListening), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let reloadItem = NSMenuItem(title: "Reload Model", action: #selector(reloadModel), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(.separator())

        hotkeyDetailItem = NSMenuItem(title: "Hotkey: \(settings.hotkey)", action: nil, keyEquivalent: "")
        hotkeyDetailItem.isEnabled = false
        menu.addItem(hotkeyDetailItem)

        stateDetailItem = NSMenuItem(title: "Status: Loading model...", action: nil, keyEquivalent: "")
        stateDetailItem.isEnabled = false
        menu.addItem(stateDetailItem)

        let openSettingsItem = NSMenuItem(title: "Open Settings File", action: #selector(openSettingsFile), keyEquivalent: "")
        openSettingsItem.target = self
        menu.addItem(openSettingsItem)

        let accessibilityItem = NSMenuItem(title: "Grant Accessibility", action: #selector(grantAccessibility), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let microphoneItem = NSMenuItem(title: "Open Microphone Settings", action: #selector(openMicrophoneSettings), keyEquivalent: "")
        microphoneItem.target = self
        menu.addItem(microphoneItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Supervoxtral", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        menuBarHealthy = true
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private func startStatusWatchdog() {
        statusWatchdog?.invalidate()
        statusWatchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.ensureStatusIndicator()
                self?.reloadSettingsIfChanged()
            }
        }
        if let statusWatchdog {
            RunLoop.main.add(statusWatchdog, forMode: .common)
        }
    }

    private func ensureStatusIndicator() {
        if statusItem == nil || statusItem.button == nil {
            setupMenuBar(forceReinstall: true)
        }

        if let button = statusItem?.button {
            button.image = image(for: currentState)
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "Supervoxtral: \(stateText(for: currentState))"
            statusItem?.isVisible = true
            menuBarHealthy = true
            NSApplication.shared.setActivationPolicy(.accessory)
        } else {
            menuBarHealthy = false
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }

    private func registerHotkey() {
        hotKey = nil
        rightCommandMonitor?.stop()
        rightCommandMonitor = nil

        let binding = HotkeyParser.parse(settings.hotkey) ?? .rightCommand

        switch binding {
        case .rightCommand:
            let monitor = RightCommandMonitor()
            monitor.onTrigger = { [weak self] in
                self?.toggleListening()
            }
            monitor.start()
            rightCommandMonitor = monitor
        case .standard(let parsed):
            hotKey = HotKey(key: parsed.key, modifiers: parsed.modifiers)
            hotKey?.keyDownHandler = { [weak self] in
                self?.toggleListening()
            }
        }
    }

    private func reloadSettingsIfChanged() {
        guard let modified = fileModificationDate(for: settingsPath) else { return }
        if let last = settingsLastModified, modified <= last { return }
        settingsLastModified = modified

        guard let data = try? Data(contentsOf: settingsPath),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            stateDetailItem.title = "Status: Settings file invalid JSON"
            return
        }

        let normalized = SettingsLoader.normalizeForRuntime(decoded)
        if normalized != settings {
            settings = normalized
            hotkeyDetailItem.title = "Hotkey: \(settings.hotkey)"
            registerHotkey()
            controller.updateSettings(settings)
            stateDetailItem.title = "Status: Settings reloaded"
            log("Settings hot-reloaded")
        }
    }

    private func fileModificationDate(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    private func updateState(_ state: ControllerState) {
        currentState = state
        ensureStatusIndicator()
        updateDockBadge(for: state)

        switch state {
        case .loading:
            toggleItem.title = "Start Dictation"
            toggleItem.isEnabled = false
            stateDetailItem.title = "Status: Loading model..."
        case .idle:
            toggleItem.title = "Start Dictation"
            toggleItem.isEnabled = true
            stateDetailItem.title = "Status: Ready"
        case .listening:
            toggleItem.title = "Stop Dictation"
            toggleItem.isEnabled = true
            stateDetailItem.title = "Status: Listening"
        case .error(let reason):
            toggleItem.title = "Start Dictation"
            toggleItem.isEnabled = true
            stateDetailItem.title = "Status: \(reason)"
        }
    }

    private func stateText(for state: ControllerState) -> String {
        switch state {
        case .loading:
            return "Loading"
        case .idle:
            return "Ready"
        case .listening:
            return "Listening"
        case .error:
            return "Error"
        }
    }

    private func image(for state: ControllerState) -> NSImage? {
        let symbolName: String
        switch state {
        case .loading:
            symbolName = "hourglass"
        case .idle:
            symbolName = "mic.slash.fill"
        case .listening:
            symbolName = "mic.fill"
        case .error:
            symbolName = "exclamationmark.triangle.fill"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Supervoxtral")
        image?.isTemplate = true
        return image
    }

    private func updateDockBadge(for state: ControllerState) {
        let badge: String
        switch state {
        case .loading:
            badge = "LOAD"
        case .idle:
            badge = "OFF"
        case .listening:
            badge = "ON"
        case .error:
            badge = "ERR"
        }
        NSApp.dockTile.badgeLabel = menuBarHealthy ? nil : badge
    }

    private func log(_ message: String) {
        AppLog.write("[supervoxtral] \(message)")
    }

    @objc
    private func toggleListening() {
        if case .loading = currentState {
            return
        }

        if !PermissionManager.isAccessibilityTrusted(prompt: false) {
            _ = PermissionManager.isAccessibilityTrusted(prompt: true)
        }

        controller.toggleListening()
    }

    @objc
    private func reloadModel() {
        controller.reloadModel()
    }

    @objc
    private func openSettingsFile() {
        NSWorkspace.shared.activateFileViewerSelecting([settingsPath])
    }

    @objc
    private func grantAccessibility() {
        _ = PermissionManager.isAccessibilityTrusted(prompt: true)
        PermissionManager.openAccessibilitySettings()
    }

    @objc
    private func openMicrophoneSettings() {
        PermissionManager.openMicrophoneSettings()
    }

    @objc
    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

private final class RightCommandMonitor {
    var onTrigger: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var rightCommandDown = false
    private var lastTriggerTime: CFAbsoluteTime = 0

    func start() {
        stop()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        rightCommandDown = false
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged else { return }
        guard event.keyCode == 54 else { return } // right command

        let isDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        if isDown && !rightCommandDown {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastTriggerTime > 0.2 {
                lastTriggerTime = now
                onTrigger?()
            }
        }

        rightCommandDown = isDown
    }

    deinit {
        stop()
    }
}

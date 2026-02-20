import AppKit
import HotKey

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var stateDetailItem: NSMenuItem!
    private var hotkeyDetailItem: NSMenuItem!
    private var modelLocationItem: NSMenuItem!
    private var modelProgressItem: NSMenuItem!
    private var modelProgressLabel: NSTextField!
    private var modelProgressIndicator: NSProgressIndicator!

    private var hotKey: HotKey?
    private var rightCommandMonitor: RightCommandMonitor?
    private var statusWatchdog: Timer?
    private var settingsWindowController: SettingsWindowController?

    private var settings: AppSettings!
    private var settingsPath: URL!
    private var settingsLastModified: Date?
    private var controller: DictationController!
    private var currentState: ControllerState = .loading
    private var menuBarHealthy = false
    private var statusDetailText = "Loading model..."
    private var downloadProgress: Double?
    private let projectURL = URL(string: "https://github.com/jphme/supervoxtral")!
    private let ellamindURL = URL(string: "https://ellamind.com")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let loaded = SettingsLoader.load()
        settings = loaded.0
        settingsPath = loaded.1
        settingsLastModified = fileModificationDate(for: settingsPath)
        settingsWindowController = SettingsWindowController()
        settingsWindowController?.onSave = { [weak self] updated in
            self?.persistSettingsFromPreferences(updated)
        }

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
            self?.handleStatusDetail(detail)
        }

        controller.onError = { [weak self] message in
            self?.handleStatusDetail(message)
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
        menu.autoenablesItems = false

        toggleItem = NSMenuItem(title: "Start Dictation", action: #selector(toggleListening), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let preferencesItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

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

        modelLocationItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        modelLocationItem.isEnabled = false
        menu.addItem(modelLocationItem)

        modelProgressItem = makeModelProgressItem()
        menu.addItem(modelProgressItem)

        let openModelCacheItem = NSMenuItem(title: "Open Model Cache", action: #selector(openModelCache), keyEquivalent: "")
        openModelCacheItem.target = self
        menu.addItem(openModelCacheItem)

        let openLogItem = NSMenuItem(title: "Open App Log", action: #selector(openAppLog), keyEquivalent: "")
        openLogItem.target = self
        menu.addItem(openLogItem)

        let openSettingsItem = NSMenuItem(title: "Open Settings File", action: #selector(openSettingsFile), keyEquivalent: "")
        openSettingsItem.target = self
        menu.addItem(openSettingsItem)

        menu.addItem(.separator())

        let accessibilityItem = NSMenuItem(title: "Grant Accessibility", action: #selector(grantAccessibility), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let microphoneItem = NSMenuItem(title: "Open Microphone Settings", action: #selector(openMicrophoneSettings), keyEquivalent: "")
        microphoneItem.target = self
        menu.addItem(microphoneItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About Supervoxtral", action: #selector(showAboutSupervoxtralPanel), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit Supervoxtral", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        menuBarHealthy = true
        NSApplication.shared.setActivationPolicy(.accessory)
        refreshStatusUI()
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
            button.toolTip = "Supervoxtral: \(statusDetailText)"
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
            handleStatusDetail("Settings file contains invalid JSON")
            return
        }

        let normalized = SettingsLoader.normalizeForRuntime(decoded)
        if normalized != settings {
            settings = normalized
            registerHotkey()
            controller.updateSettings(settings)
            handleStatusDetail("Settings reloaded")
            log("Settings hot-reloaded")
            refreshStatusUI()
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
            if statusDetailText == "Ready" || statusDetailText == "Listening" {
                statusDetailText = "Loading model..."
            }
        case .idle:
            toggleItem.title = "Start Dictation"
            toggleItem.isEnabled = true
            statusDetailText = "Ready"
            downloadProgress = nil
        case .listening:
            toggleItem.title = "Stop Dictation"
            toggleItem.isEnabled = true
            statusDetailText = "Listening"
            downloadProgress = nil
        case .error(let reason):
            toggleItem.title = "Start Dictation"
            toggleItem.isEnabled = true
            statusDetailText = reason
            downloadProgress = nil
        }
        refreshStatusUI()
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

    private func handleStatusDetail(_ detail: String) {
        statusDetailText = detail
        downloadProgress = parseProgress(from: detail)
        refreshStatusUI()
    }

    private func refreshStatusUI() {
        hotkeyDetailItem?.title = "Hotkey: \(settings?.hotkey ?? "right_cmd")"
        stateDetailItem?.title = "Status: \(statusDetailText)"

        let modelDirectory = currentModelCacheDirectory()
        let abbreviatedModelPath = (modelDirectory.path as NSString).abbreviatingWithTildeInPath
        modelLocationItem?.title = "Model cache: \(abbreviatedModelPath)"
        modelLocationItem?.toolTip = modelDirectory.path
        updateModelProgressIndicator()

        settingsWindowController?.updateRuntimeInfo(
            settingsPath: settingsPath,
            modelDirectory: modelDirectory,
            statusText: statusDetailText,
            isLoading: currentState == .loading,
            downloadProgress: downloadProgress
        )
    }

    private func updateModelProgressIndicator() {
        guard let modelProgressItem else { return }
        let isLoading = currentState == .loading
        modelProgressItem.isHidden = !isLoading

        guard isLoading else {
            modelProgressIndicator?.stopAnimation(nil)
            modelProgressIndicator?.doubleValue = 0
            modelProgressLabel?.stringValue = "Model download"
            return
        }

        if let downloadProgress {
            modelProgressIndicator?.isIndeterminate = false
            modelProgressIndicator?.doubleValue = max(0, min(100, downloadProgress * 100))
            modelProgressLabel?.stringValue = "Model download \(Int(downloadProgress * 100))%"
        } else {
            modelProgressIndicator?.isIndeterminate = true
            modelProgressIndicator?.startAnimation(nil)
            modelProgressLabel?.stringValue = "Model download in progress"
        }
    }

    private func makeModelProgressItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 32))
        view.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Model download")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 4, y: 16, width: 252, height: 14)
        view.addSubview(label)
        modelProgressLabel = label

        let indicator = NSProgressIndicator(frame: NSRect(x: 4, y: 2, width: 252, height: 12))
        indicator.minValue = 0
        indicator.maxValue = 100
        indicator.controlSize = .small
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        view.addSubview(indicator)
        modelProgressIndicator = indicator

        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        item.isHidden = true
        return item
    }

    private func parseProgress(from detail: String) -> Double? {
        if let percent = firstIntMatch(in: detail, pattern: #"(\d{1,3})%"#) {
            return Double(percent) / 100.0
        }

        if let numerator = firstIntMatch(in: detail, pattern: #"(\d+)\s*/\s*(\d+)"#, captureGroup: 1),
           let denominator = firstIntMatch(in: detail, pattern: #"(\d+)\s*/\s*(\d+)"#, captureGroup: 2),
           denominator > 0
        {
            return Double(numerator) / Double(denominator)
        }

        return nil
    }

    private func firstIntMatch(in text: String, pattern: String, captureGroup: Int = 1) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              captureGroup < match.numberOfRanges,
              let groupRange = Range(match.range(at: captureGroup), in: text)
        else {
            return nil
        }
        return Int(text[groupRange])
    }

    private func currentModelCacheDirectory() -> URL {
        let modelSubdir = settings.modelId.replacingOccurrences(of: "/", with: "_")
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/supervoxtral", isDirectory: true)
        return base.appendingPathComponent(modelSubdir, isDirectory: true)
    }

    private func persistSettingsFromPreferences(_ updated: AppSettings) {
        let normalized = SettingsLoader.normalizeForRuntime(updated)
        do {
            try SettingsLoader.save(normalized, to: settingsPath)
            settings = normalized
            settingsLastModified = fileModificationDate(for: settingsPath)
            registerHotkey()
            controller.updateSettings(settings)
            handleStatusDetail("Settings saved")
            log("Settings saved from Preferences")
        } catch {
            handleStatusDetail("Failed to save settings: \(error.localizedDescription)")
        }
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
    private func openPreferences() {
        settingsWindowController?.present(
            settings: settings,
            settingsPath: settingsPath,
            modelDirectory: currentModelCacheDirectory(),
            statusText: statusDetailText,
            isLoading: currentState == .loading,
            downloadProgress: downloadProgress
        )
    }

    @objc
    private func openModelCache() {
        let modelDirectory = currentModelCacheDirectory()
        let fallbackDirectory = modelDirectory.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: modelDirectory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([modelDirectory])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([fallbackDirectory])
        }
    }

    @objc
    private func openSettingsFile() {
        NSWorkspace.shared.activateFileViewerSelecting([settingsPath])
    }

    @objc
    private func openAppLog() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: AppLog.path())])
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
    private func showAboutSupervoxtralPanel() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "About Supervoxtral"
        alert.informativeText = "Voxtral Mini Realtime 8bit (MLX) integration for Supervoxtral."
        alert.addButton(withTitle: "Open GitHub")
        alert.addButton(withTitle: "Open ellamind")
        alert.addButton(withTitle: "Close")
        alert.accessoryView = makeAboutModelAccessoryView()

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(projectURL)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(ellamindURL)
        default:
            break
        }
    }

    private func makeAboutModelAccessoryView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let creatorField = NSTextField(labelWithString: "created by JP Harries")
        creatorField.font = .systemFont(ofSize: 12, weight: .medium)

        stack.addArrangedSubview(creatorField)
        stack.addArrangedSubview(makeLinkField(label: "GitHub: ", url: projectURL))
        stack.addArrangedSubview(makeLinkField(label: "ellamind: ", url: ellamindURL))
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 82)
        return stack
    }

    private func makeLinkField(label: String, url: URL) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.allowsEditingTextAttributes = true
        field.isSelectable = true

        let fullText = "\(label)\(url.absoluteString)"
        let value = NSMutableAttributedString(string: fullText)
        value.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: label.count))
        value.addAttribute(.link, value: url, range: NSRange(location: label.count, length: url.absoluteString.count))
        value.addAttribute(.foregroundColor, value: NSColor.linkColor, range: NSRange(location: label.count, length: url.absoluteString.count))
        value.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: label.count, length: url.absoluteString.count))
        field.attributedStringValue = value
        return field
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

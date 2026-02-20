import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    var onSave: ((AppSettings) -> Void)?

    private var currentSettings: AppSettings = .default
    private var settingsPath: URL = URL(fileURLWithPath: "")
    private var modelDirectory: URL = URL(fileURLWithPath: "")
    private var hasCenteredWindow = false

    private let settingsPathField = SettingsWindowController.makePathField()
    private let modelPathField = SettingsWindowController.makePathField()
    private let modelStatusField = NSTextField(labelWithString: "Status: Idle")
    private let modelProgressIndicator = NSProgressIndicator()

    private let modelIdField = NSTextField()
    private let hfTokenField = NSSecureTextField()
    private let hotkeyField = NSTextField()
    private let mlxDeviceField = NSPopUpButton()
    private let decodeIntervalField = NSTextField()
    private let minSamplesField = NSTextField()
    private let languageField = NSTextField()
    private let temperatureField = NSTextField()
    private let maxTokensField = NSTextField()
    private let transcriptionDelayField = NSTextField()
    private let modelTimeoutField = NSTextField()
    private let contextWindowField = NSTextField()
    private let contentBiasTokenField = NSTokenField()
    private let contentBiasStrengthField = NSTextField()
    private let contentBiasFirstTokenFactorField = NSTextField()
    private let transcriptPrefixTextView = NSTextView()
    private let transcriptSuffixTextView = NSTextView()

    private lazy var prefixScrollView = makeMultilineContainer(for: transcriptPrefixTextView)
    private lazy var suffixScrollView = makeMultilineContainer(for: transcriptSuffixTextView)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Supervoxtral Preferences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(
        settings: AppSettings,
        settingsPath: URL,
        modelDirectory: URL,
        statusText: String,
        isLoading: Bool,
        downloadProgress: Double?
    ) {
        self.settingsPath = settingsPath
        self.modelDirectory = modelDirectory
        populate(with: settings)
        updateRuntimeInfo(
            settingsPath: settingsPath,
            modelDirectory: modelDirectory,
            statusText: statusText,
            isLoading: isLoading,
            downloadProgress: downloadProgress
        )
        showWindow(nil)
        if !hasCenteredWindow {
            window?.center()
            hasCenteredWindow = true
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateRuntimeInfo(
        settingsPath: URL,
        modelDirectory: URL,
        statusText: String,
        isLoading: Bool,
        downloadProgress: Double?
    ) {
        self.settingsPath = settingsPath
        self.modelDirectory = modelDirectory

        settingsPathField.stringValue = settingsPath.path
        modelPathField.stringValue = modelDirectory.path
        modelStatusField.stringValue = "Status: \(statusText)"

        modelProgressIndicator.isHidden = !isLoading
        if isLoading {
            if let downloadProgress {
                modelProgressIndicator.isIndeterminate = false
                modelProgressIndicator.doubleValue = max(0, min(100, downloadProgress * 100))
            } else {
                modelProgressIndicator.isIndeterminate = true
                modelProgressIndicator.startAnimation(nil)
            }
        } else {
            modelProgressIndicator.stopAnimation(nil)
            modelProgressIndicator.doubleValue = 0
        }
    }
}

private extension SettingsWindowController {
    func configureUI() {
        guard let window, let contentView = window.contentView else { return }

        window.minSize = NSSize(width: 700, height: 760)

        let buttonBar = NSStackView()
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 8
        contentView.addSubview(buttonBar)

        modelStatusField.font = .systemFont(ofSize: 12, weight: .medium)
        modelProgressIndicator.minValue = 0
        modelProgressIndicator.maxValue = 100
        modelProgressIndicator.controlSize = .small
        modelProgressIndicator.isIndeterminate = true
        modelProgressIndicator.style = .bar
        modelProgressIndicator.isHidden = true
        modelProgressIndicator.translatesAutoresizingMaskIntoConstraints = false
        modelProgressIndicator.widthAnchor.constraint(equalToConstant: 280).isActive = true

        mlxDeviceField.addItems(withTitles: ["gpu", "cpu"])
        mlxDeviceField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        contentBiasTokenField.tokenizingCharacterSet = CharacterSet(charactersIn: ",\n")

        transcriptPrefixTextView.isRichText = false
        transcriptPrefixTextView.usesFontPanel = false
        transcriptPrefixTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        transcriptPrefixTextView.textColor = .labelColor
        transcriptPrefixTextView.backgroundColor = .textBackgroundColor
        transcriptPrefixTextView.insertionPointColor = .labelColor
        transcriptPrefixTextView.isEditable = true
        transcriptPrefixTextView.isSelectable = true
        transcriptSuffixTextView.isRichText = false
        transcriptSuffixTextView.usesFontPanel = false
        transcriptSuffixTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        transcriptSuffixTextView.textColor = .labelColor
        transcriptSuffixTextView.backgroundColor = .textBackgroundColor
        transcriptSuffixTextView.insertionPointColor = .labelColor
        transcriptSuffixTextView.isEditable = true
        transcriptSuffixTextView.isSelectable = true

        let runtimeHeading = NSTextField(labelWithString: "Runtime")
        runtimeHeading.font = .systemFont(ofSize: 14, weight: .semibold)
        runtimeHeading.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(runtimeHeading)

        let runtimeStack = makeVerticalStack(spacing: 10)
        runtimeStack.addArrangedSubview(makeFieldGroup(
            title: "Settings file",
            control: settingsPathField,
            helpText: "Saved settings are reloaded automatically while the app is running."
        ))
        runtimeStack.addArrangedSubview(makeFieldGroup(title: "Model cache", control: modelPathField))
        runtimeStack.addArrangedSubview(makeFieldGroup(title: "Model status", control: modelStatusField))
        runtimeStack.addArrangedSubview(makeFieldGroup(title: "Model download progress", control: modelProgressIndicator))
        contentView.addSubview(runtimeStack)

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .topTabsBezelBorder

        tabView.addTabViewItem(makeTabItem(
            title: "General",
            groups: [
                makeFieldGroup(title: "Model ID", control: modelIdField),
                makeFieldGroup(title: "HF token", control: hfTokenField, helpText: "Leave blank for public models."),
                makeFieldGroup(title: "MLX device", control: mlxDeviceField),
                makeFieldGroup(title: "Model load timeout (seconds)", control: modelTimeoutField),
                makeFieldGroup(title: "Language", control: languageField),
                makeFieldGroup(title: "Temperature", control: temperatureField),
                makeFieldGroup(title: "Max tokens", control: maxTokensField),
                makeFieldGroup(title: "Transcription delay (ms)", control: transcriptionDelayField),
                makeFieldGroup(title: "Context window (seconds)", control: contextWindowField),
                makeFieldGroup(title: "Hotkey", control: hotkeyField),
                makeFieldGroup(title: "Decode interval (ms)", control: decodeIntervalField),
                makeFieldGroup(title: "Min samples for decode", control: minSamplesField),
            ]
        ))

        tabView.addTabViewItem(makeTabItem(
            title: "Content Bias",
            groups: [
                makeFieldGroup(
                    title: "Bias terms",
                    control: contentBiasTokenField,
                    helpText: "Up to 100 terms. Use Enter or comma to add each term."
                ),
                makeFieldGroup(title: "Bias strength", control: contentBiasStrengthField),
                makeFieldGroup(title: "First-token factor", control: contentBiasFirstTokenFactorField),
            ]
        ))

        tabView.addTabViewItem(makeTabItem(
            title: "Framing",
            groups: [
                makeFieldGroup(
                    title: "Transcript prefix",
                    control: prefixScrollView,
                    helpText: "Inserted once when dictation starts."
                ),
                makeFieldGroup(
                    title: "Transcript suffix",
                    control: suffixScrollView,
                    helpText: "Inserted once when dictation stops."
                ),
            ]
        ))
        contentView.addSubview(tabView)

        let openSettingsButton = NSButton(title: "Open Settings File", target: self, action: #selector(openSettingsFile))
        let openModelCacheButton = NSButton(title: "Open Model Cache", target: self, action: #selector(openModelCache))
        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetToDefaults))
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelChanges))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveChanges))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        saveButton.setButtonType(.momentaryPushIn)
        saveButton.isBordered = true

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true

        buttonBar.addArrangedSubview(openSettingsButton)
        buttonBar.addArrangedSubview(openModelCacheButton)
        buttonBar.addArrangedSubview(resetButton)
        buttonBar.addArrangedSubview(spacer)
        buttonBar.addArrangedSubview(cancelButton)
        buttonBar.addArrangedSubview(saveButton)

        NSLayoutConstraint.activate([
            runtimeHeading.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            runtimeHeading.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            runtimeHeading.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),

            runtimeStack.topAnchor.constraint(equalTo: runtimeHeading.bottomAnchor, constant: 6),
            runtimeStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            runtimeStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),

            tabView.topAnchor.constraint(equalTo: runtimeStack.bottomAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            tabView.heightAnchor.constraint(greaterThanOrEqualToConstant: 440),

            buttonBar.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 12),
            buttonBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            buttonBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttonBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    func populate(with settings: AppSettings) {
        currentSettings = settings

        modelIdField.stringValue = settings.modelId
        hfTokenField.stringValue = settings.hfToken ?? ""
        hotkeyField.stringValue = settings.hotkey
        mlxDeviceField.selectItem(withTitle: settings.mlxDevice ?? "gpu")
        decodeIntervalField.stringValue = "\(settings.decodeIntervalMs)"
        minSamplesField.stringValue = "\(settings.minSamplesForDecode)"
        languageField.stringValue = settings.language
        temperatureField.stringValue = "\(settings.temperature)"
        maxTokensField.stringValue = "\(settings.maxTokens)"
        transcriptionDelayField.stringValue = "\(settings.transcriptionDelayMs)"
        modelTimeoutField.stringValue = "\(settings.modelLoadTimeoutSeconds ?? 240)"
        contextWindowField.stringValue = "\(settings.contextWindowSeconds)"
        contentBiasTokenField.objectValue = settings.contentBias
        contentBiasStrengthField.stringValue = "\(settings.contentBiasStrength)"
        contentBiasFirstTokenFactorField.stringValue = "\(settings.contentBiasFirstTokenFactor)"
        transcriptPrefixTextView.string = settings.transcriptPrefix
        transcriptSuffixTextView.string = settings.transcriptSuffix
    }

    func makeMultilineContainer(for textView: NSTextView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 86).isActive = true

        textView.drawsBackground = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        return scrollView
    }

    func makeVerticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    func makeTabItem(title: String, groups: [NSView]) -> NSTabViewItem {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = makeVerticalStack(spacing: 10)
        for group in groups {
            stack.addArrangedSubview(group)
        }
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -14),
        ])

        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = container
        return item
    }

    func makeFieldGroup(title: String, control: NSView, helpText: String? = nil) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(titleField)

        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        stack.addArrangedSubview(control)

        if let helpText, !helpText.isEmpty {
            let help = NSTextField(labelWithString: helpText)
            help.font = .systemFont(ofSize: 11)
            help.textColor = .secondaryLabelColor
            help.lineBreakMode = .byWordWrapping
            help.maximumNumberOfLines = 2
            stack.addArrangedSubview(help)
        }

        return stack
    }

    static func makePathField() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.isSelectable = true
        return field
    }

    @objc
    func openSettingsFile() {
        guard !settingsPath.path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([settingsPath])
    }

    @objc
    func openModelCache() {
        guard !modelDirectory.path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([modelDirectory])
    }

    @objc
    func resetToDefaults() {
        populate(with: .default)
    }

    @objc
    func cancelChanges() {
        window?.orderOut(nil)
    }

    @objc
    func saveChanges() {
        var updated = currentSettings

        let trimmedModelId = modelIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModelId.isEmpty {
            updated.modelId = trimmedModelId
        }

        let hfToken = hfTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.hfToken = hfToken.isEmpty ? nil : hfToken

        let hotkey = hotkeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hotkey.isEmpty {
            updated.hotkey = hotkey
        }

        updated.mlxDevice = mlxDeviceField.selectedItem?.title.lowercased()
        updated.decodeIntervalMs = Int(decodeIntervalField.stringValue) ?? updated.decodeIntervalMs
        updated.minSamplesForDecode = Int(minSamplesField.stringValue) ?? updated.minSamplesForDecode

        let language = languageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !language.isEmpty {
            updated.language = language
        }

        updated.temperature = Float(temperatureField.stringValue) ?? updated.temperature
        updated.maxTokens = Int(maxTokensField.stringValue) ?? updated.maxTokens
        updated.transcriptionDelayMs = Int(transcriptionDelayField.stringValue) ?? updated.transcriptionDelayMs
        updated.modelLoadTimeoutSeconds = Double(modelTimeoutField.stringValue) ?? updated.modelLoadTimeoutSeconds
        updated.contextWindowSeconds = Double(contextWindowField.stringValue) ?? updated.contextWindowSeconds

        if let terms = contentBiasTokenField.objectValue as? [String] {
            updated.contentBias = terms
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            updated.contentBias = []
        }

        updated.contentBiasStrength = Float(contentBiasStrengthField.stringValue) ?? updated.contentBiasStrength
        updated.contentBiasFirstTokenFactor = Float(contentBiasFirstTokenFactorField.stringValue) ?? updated.contentBiasFirstTokenFactor
        updated.transcriptPrefix = transcriptPrefixTextView.string
        updated.transcriptSuffix = transcriptSuffixTextView.string

        onSave?(SettingsLoader.normalizeForRuntime(updated))
    }
}

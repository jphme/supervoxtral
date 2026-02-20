import Foundation
import AppKit
import HotKey

struct AppSettings: Codable, Equatable {
    var hfToken: String?
    var modelId: String
    var hotkey: String
    var decodeIntervalMs: Int
    var contextWindowSeconds: Double
    var minSamplesForDecode: Int
    var temperature: Float
    var maxTokens: Int
    var language: String
    var transcriptionDelayMs: Int
    var modelLoadTimeoutSeconds: Double?
    var mlxDevice: String?
    var contentBias: [String]
    var contentBiasStrength: Float
    var contentBiasFirstTokenFactor: Float
    var transcriptPrefix: String
    var transcriptSuffix: String

    static let `default` = AppSettings(
        hfToken: nil,
        modelId: "ellamind/Voxtral-Mini-4B-Realtime-8bit-mlx",
        hotkey: "right_cmd",
        decodeIntervalMs: 40,
        contextWindowSeconds: 18.0,
        minSamplesForDecode: 1280,
        temperature: 0.0,
        maxTokens: 512,
        language: "auto",
        transcriptionDelayMs: 480,
        modelLoadTimeoutSeconds: 240,
        mlxDevice: "gpu",
        contentBias: [],
        contentBiasStrength: 5.0,
        contentBiasFirstTokenFactor: 0.2,
        transcriptPrefix: "",
        transcriptSuffix: ""
    )

    enum CodingKeys: String, CodingKey {
        case hfToken
        case modelId
        case hotkey
        case decodeIntervalMs
        case contextWindowSeconds
        case minSamplesForDecode
        case temperature
        case maxTokens
        case language
        case transcriptionDelayMs
        case modelLoadTimeoutSeconds
        case mlxDevice
        case contentBias
        case contextBias
        case contentBiasSnake = "content_bias"
        case contextBiasSnake = "context_bias"
        case contentBiasStrength
        case contextBiasStrength
        case contentBiasStrengthSnake = "content_bias_strength"
        case contextBiasStrengthSnake = "context_bias_strength"
        case contentBiasFirstTokenFactor
        case contextBiasFirstTokenFactor
        case contentBiasFirstTokenFactorSnake = "content_bias_first_token_factor"
        case contextBiasFirstTokenFactorSnake = "context_bias_first_token_factor"
        case transcriptPrefix
        case transcriptPrefixSnake = "transcript_prefix"
        case textPrefix
        case prefix
        case transcriptSuffix
        case transcriptSuffixSnake = "transcript_suffix"
        case textSuffix
        case suffix
    }

    init(
        hfToken: String?,
        modelId: String,
        hotkey: String,
        decodeIntervalMs: Int,
        contextWindowSeconds: Double,
        minSamplesForDecode: Int,
        temperature: Float,
        maxTokens: Int,
        language: String,
        transcriptionDelayMs: Int,
        modelLoadTimeoutSeconds: Double?,
        mlxDevice: String?,
        contentBias: [String],
        contentBiasStrength: Float,
        contentBiasFirstTokenFactor: Float,
        transcriptPrefix: String,
        transcriptSuffix: String
    ) {
        self.hfToken = hfToken
        self.modelId = modelId
        self.hotkey = hotkey
        self.decodeIntervalMs = decodeIntervalMs
        self.contextWindowSeconds = contextWindowSeconds
        self.minSamplesForDecode = minSamplesForDecode
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.language = language
        self.transcriptionDelayMs = transcriptionDelayMs
        self.modelLoadTimeoutSeconds = modelLoadTimeoutSeconds
        self.mlxDevice = mlxDevice
        self.contentBias = contentBias
        self.contentBiasStrength = contentBiasStrength
        self.contentBiasFirstTokenFactor = contentBiasFirstTokenFactor
        self.transcriptPrefix = transcriptPrefix
        self.transcriptSuffix = transcriptSuffix
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings.default

        hfToken = try container.decodeIfPresent(String.self, forKey: .hfToken)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? defaults.modelId
        hotkey = try container.decodeIfPresent(String.self, forKey: .hotkey) ?? defaults.hotkey
        decodeIntervalMs = try container.decodeIfPresent(Int.self, forKey: .decodeIntervalMs) ?? defaults.decodeIntervalMs
        contextWindowSeconds = try container.decodeIfPresent(Double.self, forKey: .contextWindowSeconds) ?? defaults.contextWindowSeconds
        minSamplesForDecode = try container.decodeIfPresent(Int.self, forKey: .minSamplesForDecode) ?? defaults.minSamplesForDecode
        temperature = try container.decodeIfPresent(Float.self, forKey: .temperature) ?? defaults.temperature
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? defaults.maxTokens
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? defaults.language
        transcriptionDelayMs = try container.decodeIfPresent(Int.self, forKey: .transcriptionDelayMs) ?? defaults.transcriptionDelayMs
        modelLoadTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .modelLoadTimeoutSeconds) ?? defaults.modelLoadTimeoutSeconds
        mlxDevice = try container.decodeIfPresent(String.self, forKey: .mlxDevice) ?? defaults.mlxDevice

        contentBias = try container.decodeIfPresent([String].self, forKey: .contentBias)
            ?? container.decodeIfPresent([String].self, forKey: .contextBias)
            ?? container.decodeIfPresent([String].self, forKey: .contentBiasSnake)
            ?? container.decodeIfPresent([String].self, forKey: .contextBiasSnake)
            ?? defaults.contentBias

        contentBiasStrength = try container.decodeIfPresent(Float.self, forKey: .contentBiasStrength)
            ?? container.decodeIfPresent(Float.self, forKey: .contextBiasStrength)
            ?? container.decodeIfPresent(Float.self, forKey: .contentBiasStrengthSnake)
            ?? container.decodeIfPresent(Float.self, forKey: .contextBiasStrengthSnake)
            ?? defaults.contentBiasStrength

        contentBiasFirstTokenFactor = try container.decodeIfPresent(Float.self, forKey: .contentBiasFirstTokenFactor)
            ?? container.decodeIfPresent(Float.self, forKey: .contextBiasFirstTokenFactor)
            ?? container.decodeIfPresent(Float.self, forKey: .contentBiasFirstTokenFactorSnake)
            ?? container.decodeIfPresent(Float.self, forKey: .contextBiasFirstTokenFactorSnake)
            ?? defaults.contentBiasFirstTokenFactor

        transcriptPrefix = try container.decodeIfPresent(String.self, forKey: .transcriptPrefix)
            ?? container.decodeIfPresent(String.self, forKey: .transcriptPrefixSnake)
            ?? container.decodeIfPresent(String.self, forKey: .textPrefix)
            ?? container.decodeIfPresent(String.self, forKey: .prefix)
            ?? defaults.transcriptPrefix

        transcriptSuffix = try container.decodeIfPresent(String.self, forKey: .transcriptSuffix)
            ?? container.decodeIfPresent(String.self, forKey: .transcriptSuffixSnake)
            ?? container.decodeIfPresent(String.self, forKey: .textSuffix)
            ?? container.decodeIfPresent(String.self, forKey: .suffix)
            ?? defaults.transcriptSuffix
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(hfToken, forKey: .hfToken)
        try container.encode(modelId, forKey: .modelId)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(decodeIntervalMs, forKey: .decodeIntervalMs)
        try container.encode(contextWindowSeconds, forKey: .contextWindowSeconds)
        try container.encode(minSamplesForDecode, forKey: .minSamplesForDecode)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(language, forKey: .language)
        try container.encode(transcriptionDelayMs, forKey: .transcriptionDelayMs)
        try container.encodeIfPresent(modelLoadTimeoutSeconds, forKey: .modelLoadTimeoutSeconds)
        try container.encodeIfPresent(mlxDevice, forKey: .mlxDevice)
        try container.encode(contentBias, forKey: .contentBias)
        try container.encode(contentBiasStrength, forKey: .contentBiasStrength)
        try container.encode(contentBiasFirstTokenFactor, forKey: .contentBiasFirstTokenFactor)
        try container.encode(transcriptPrefix, forKey: .transcriptPrefix)
        try container.encode(transcriptSuffix, forKey: .transcriptSuffix)
    }
}

enum SettingsLoader {
    static func load() -> (AppSettings, URL) {
        let candidates = settingsCandidates()
        for path in candidates {
            if let data = try? Data(contentsOf: path),
               let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
                let migrated = normalizeForRuntime(settings)
                persistIfChanged(original: settings, migrated: migrated, path: path)
                return (migrated, path)
            }
        }

        let userSettingsPath = defaultSettingsPath()
        if let bundledURL = bundledSettingsURL(),
           let data = try? Data(contentsOf: bundledURL),
           let bundled = try? JSONDecoder().decode(AppSettings.self, from: data) {
            writeSettingsIfMissing(bundled, to: userSettingsPath)
            if let persistedData = try? Data(contentsOf: userSettingsPath),
               let persisted = try? JSONDecoder().decode(AppSettings.self, from: persistedData) {
                let migrated = normalizeForRuntime(persisted)
                persistIfChanged(original: persisted, migrated: migrated, path: userSettingsPath)
                return (migrated, userSettingsPath)
            }
            let migrated = normalizeForRuntime(bundled)
            persistIfChanged(original: bundled, migrated: migrated, path: bundledURL)
            return (migrated, bundledURL)
        }

        writeSettingsIfMissing(AppSettings.default, to: userSettingsPath)
        return (AppSettings.default, userSettingsPath)
    }

    private static func settingsCandidates() -> [URL] {
        var urls: [URL] = []
        if let envPath = ProcessInfo.processInfo.environment["SUPERVOXTRAL_SETTINGS"], !envPath.isEmpty {
            urls.append(URL(fileURLWithPath: envPath))
        }
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("config/settings.json"))
        urls.append(defaultSettingsPath())
        return urls
    }

    private static func defaultSettingsPath() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Supervoxtral/settings.json")
    }

    private static func bundledSettingsURL() -> URL? {
        Bundle.main.url(forResource: "settings.default", withExtension: "json")
    }

    private static func writeSettingsIfMissing(_ settings: AppSettings, to url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.pretty.encode(settings)
            try data.write(to: url, options: .atomic)
        } catch {
            // Ignore write failures; the app can still run with defaults.
        }
    }

    static func save(_ settings: AppSettings, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(settings)
        try data.write(to: url, options: .atomic)
    }

    static func normalizeForRuntime(_ settings: AppSettings) -> AppSettings {
        var migrated = settings

        let hotkey = settings.hotkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if hotkey == "ctrl+alt+cmd+space"
            || hotkey == "<ctrl>+<alt>+<cmd>+<space>"
            || hotkey == "control+option+command+space"
        {
            migrated.hotkey = "right_cmd"
        }

        if settings.decodeIntervalMs == 700 {
            migrated.decodeIntervalMs = 40
        }

        if settings.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "en" {
            migrated.language = "auto"
        }

        // Older builds used large decode batches tuned for chunked mode.
        // Streaming mode is stable and responsive at 1280 samples (80ms at 16kHz).
        if settings.minSamplesForDecode == 6400 {
            migrated.minSamplesForDecode = 1280
        }

        if settings.mlxDevice == nil || settings.mlxDevice?.isEmpty == true {
            migrated.mlxDevice = "gpu"
        }

        let normalizedBiasTerms = settings.contentBias
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        migrated.contentBias = Array(normalizedBiasTerms.prefix(100))

        if settings.contentBiasStrength <= 0 {
            migrated.contentBiasStrength = 5.0
        }

        migrated.contentBiasFirstTokenFactor = min(1.0, max(0.0, settings.contentBiasFirstTokenFactor))

        return migrated
    }

    private static func persistIfChanged(original: AppSettings, migrated: AppSettings, path: URL) {
        guard original != migrated else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.pretty.encode(migrated)
            try data.write(to: path, options: .atomic)
        } catch {
            // Best-effort migration persistence.
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

struct ParsedHotkey {
    let key: Key
    let modifiers: NSEvent.ModifierFlags
}

enum HotkeyBinding {
    case rightCommand
    case standard(ParsedHotkey)
}

enum HotkeyParser {
    static func parse(_ input: String) -> HotkeyBinding? {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized == "right_cmd"
            || normalized == "right_command"
            || normalized == "rcmd"
        {
            return .rightCommand
        }

        let rawTokens = input
            .lowercased()
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !rawTokens.isEmpty else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        var keyToken: String?

        for token in rawTokens {
            switch token {
            case "ctrl", "control":
                modifiers.insert(.control)
            case "alt", "option":
                modifiers.insert(.option)
            case "cmd", "command":
                modifiers.insert(.command)
            case "shift":
                modifiers.insert(.shift)
            default:
                keyToken = token
            }
        }

        guard let keyToken, let key = Key(string: keyToken) else {
            return nil
        }

        return .standard(ParsedHotkey(key: key, modifiers: modifiers))
    }
}

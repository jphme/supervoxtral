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
        mlxDevice: "gpu"
    )
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

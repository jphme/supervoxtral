import Foundation

enum AppLog {
    private static let queue = DispatchQueue(label: "supervoxtral.log")

    private static let logURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/Supervoxtral/app.log")
    }()

    static func write(_ message: String) {
        let line = "[\(timestamp())] \(message)\n"
        queue.async {
            do {
                let dir = logURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                if !FileManager.default.fileExists(atPath: logURL.path) {
                    try line.data(using: .utf8)?.write(to: logURL, options: .atomic)
                    return
                }

                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                // Keep logging best-effort and never crash app behavior.
            }
        }
    }

    static func path() -> String {
        logURL.path
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

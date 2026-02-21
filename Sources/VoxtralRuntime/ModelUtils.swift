import Foundation
import HuggingFace

public enum ModelUtils {
    public static func resolveOrDownloadModel(
        repoID: Repo.ID,
        requiredExtension: String,
        hfToken: String? = nil,
        progressHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let client: HubClient
        if let token = hfToken, !token.isEmpty {
            client = HubClient(host: HubClient.defaultHost, bearerToken: token)
        } else {
            client = HubClient.default
        }
        let cache = client.cache ?? HubCache.default
        return try await resolveOrDownloadModel(
            client: client,
            cache: cache,
            repoID: repoID,
            requiredExtension: requiredExtension,
            progressHandler: progressHandler
        )
    }

    public static func resolveOrDownloadModel(
        client: HubClient,
        cache: HubCache,
        repoID: Repo.ID,
        requiredExtension: String,
        progressHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        progressHandler?("Checking local model cache")
        let modelSubdir = repoID.description.replacingOccurrences(of: "/", with: "_")
        let modelDir = URL.cachesDirectory.appendingPathComponent("supervoxtral").appendingPathComponent(modelSubdir)

        if FileManager.default.fileExists(atPath: modelDir.path) {
            let files = try? FileManager.default.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)
            let hasWeights = files?.contains { $0.pathExtension == requiredExtension } ?? false
            let hasConfig = FileManager.default.fileExists(atPath: modelDir.appendingPathComponent("config.json").path)
            let hasTokenizer = FileManager.default.fileExists(atPath: modelDir.appendingPathComponent("tekken.json").path)
            if hasWeights && hasConfig && hasTokenizer {
                let configPath = modelDir.appendingPathComponent("config.json")
                if let configData = try? Data(contentsOf: configPath),
                   (try? JSONSerialization.jsonObject(with: configData)) != nil {
                    progressHandler?("Using cached model files")
                    return modelDir
                }
            }

            // Cache validation failed — remove required files that are missing or corrupt
            // so the download loop will re-fetch them instead of skipping existing files.
            let requiredFiles = ["config.json", "tekken.json"]
            for name in requiredFiles {
                let path = modelDir.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: path.path),
                      let data = try? Data(contentsOf: path),
                      !data.isEmpty,
                      (try? JSONSerialization.jsonObject(with: data)) != nil
                else {
                    try? FileManager.default.removeItem(at: path)
                    continue
                }
            }
        }

        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let allowedExtensions: Set<String> = ["*.\(requiredExtension)", "*.safetensors", "*.json", "*.txt", "*.wav"]
        progressHandler?("Fetching file list")

        let entries = try await client.listFiles(in: repoID, kind: .model, revision: "main", recursive: true)
            .filter { entry in
                guard entry.type == .file else { return false }
                return allowedExtensions.contains { glob in
                    fnmatch(glob, entry.path, 0) == 0
                }
            }
            .sorted { ($0.size ?? 0) < ($1.size ?? 0) }

        progressHandler?("Downloading model files")
        var totalBytes: Int64 = 0
        var completedBytes: Int64 = 0
        for entry in entries {
            totalBytes += Int64(entry.size ?? 0)
        }

        for (index, entry) in entries.enumerated() {
            let destination = modelDir.appendingPathComponent(entry.path)
            if FileManager.default.fileExists(atPath: destination.path) {
                progressHandler?("Cached \(entry.path) (\(index + 1)/\(entries.count))")
                continue
            }
            progressHandler?("Downloading \(entry.path) (\(index)/\(entries.count))")
            _ = try await client.downloadFile(
                entry,
                from: repoID,
                to: destination,
                kind: .model,
                revision: "main"
            )
            progressHandler?("Downloaded \(entry.path) (\(index + 1)/\(entries.count))")
        }
        progressHandler?("Download complete")

        return modelDir
    }
}

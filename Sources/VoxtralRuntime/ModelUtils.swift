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
        }

        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let allowedExtensions: Set<String> = ["*.\(requiredExtension)", "*.safetensors", "*.json", "*.txt", "*.wav"]
        progressHandler?("Downloading model files")

        _ = try await client.downloadSnapshot(
            of: repoID,
            kind: .model,
            to: modelDir,
            revision: "main",
            matching: Array(allowedExtensions),
            progressHandler: { progress in
                let total = max(progress.totalUnitCount, 1)
                let completed = min(progress.completedUnitCount, total)
                let percent = Int((Double(completed) / Double(total)) * 100.0)
                progressHandler?("Downloading model files \(completed)/\(total) (\(percent)%)")
            }
        )
        progressHandler?("Download complete")

        return modelDir
    }
}

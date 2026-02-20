import Foundation
import MLX
import VoxtralRuntime

@main
struct VoxtralSmoke {
    static func main() async {
        do {
            let device = smokeDevice()
            try Device.withDefaultDevice(device) {
                let modelDir = modelDirectory()
                print("[voxtral-smoke] Device: \(device)")
                print("[voxtral-smoke] Model dir: \(modelDir.path)")
                let start = Date()
                let model = try VoxtralRealtimeModel.fromDirectory(modelDir) { status in
                    print("[voxtral-smoke] \(status)")
                }
                let loadSeconds = Date().timeIntervalSince(start)
                print("[voxtral-smoke] Model loaded in \(String(format: "%.2fs", loadSeconds))")

                let sampleCount = 16000 * 2
                let audio = MLXArray.zeros([sampleCount], type: Float.self)
                let params = STTGenerateParameters(
                    maxTokens: 64,
                    temperature: 0.0,
                    topP: 1.0,
                    topK: 0,
                    verbose: false,
                    language: "en",
                    chunkDuration: 2.0,
                    minChunkDuration: 1.0
                )
                let out = model.generate(audio: audio, generationParameters: params)
                print("[voxtral-smoke] Inference finished. text_length=\(out.text.count) total_tokens=\(out.totalTokens)")
            }
        } catch {
            fputs("[voxtral-smoke] ERROR: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func modelDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["SUPERVOXTRAL_MODEL_DIR"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = "\(home)/Library/Caches/supervoxtral/ellamind_Voxtral-Mini-4B-Realtime-8bit-mlx"
        return URL(fileURLWithPath: fallback)
    }

    private static func smokeDevice() -> Device {
        let env = ProcessInfo.processInfo.environment
        let raw = env["SUPERVOXTRAL_SMOKE_DEVICE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "cpu":
            return .cpu
        default:
            return .gpu
        }
    }
}

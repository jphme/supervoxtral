import AVFoundation
import Foundation
import MLX
import VoxtralRuntime

@main
struct VoxtralStreamFile {
    static func main() async {
        do {
            let args = try parseArgs()
            let modelDir = modelDirectory()

            let device = args.device == "cpu" ? Device.cpu : Device.gpu
            let runInDeviceScope = {
                print("[stream-file] Device: \(device)")
                print("[stream-file] Model dir: \(modelDir.path)")
                print("[stream-file] Audio: \(args.audioURL.path)")

                let model = try VoxtralRealtimeModel.fromDirectory(modelDir) { status in
                    if status.contains("Loading weights") || status.contains("Model runtime ready") {
                        print("[stream-file] \(status)")
                    }
                }

                let samples = try loadMono16kSamples(from: args.audioURL)
                print("[stream-file] Samples: \(samples.count)")

                let params = STTGenerateParameters(
                    maxTokens: args.maxTokens,
                    temperature: args.temperature,
                    topP: 1.0,
                    topK: 0,
                    verbose: false,
                    language: args.language,
                    chunkDuration: 60,
                    minChunkDuration: 1.0
                )

                let session = VoxtralRealtimeStreamingSession(
                    model: model,
                    generationParameters: params,
                    transcriptionDelayMs: args.transcriptionDelayMs
                )

                session.warmup()

                let chunk = max(1, args.ingestSamples)
                var idx = 0
                var totalText = ""
                var deltaCount = 0
                var maxGapChunks = 0
                var gapChunks = 0
                let started = Date()

                while idx < samples.count {
                    let end = min(idx + chunk, samples.count)
                    let delta: String
                    if args.deviceScope == "per-call" {
                        delta = Device.withDefaultDevice(device) {
                            session.consume(audioSamples: Array(samples[idx..<end]))
                        }
                    } else {
                        delta = session.consume(audioSamples: Array(samples[idx..<end]))
                    }
                    if delta.isEmpty {
                        gapChunks += 1
                    } else {
                        deltaCount += 1
                        maxGapChunks = max(maxGapChunks, gapChunks)
                        gapChunks = 0
                        totalText += delta
                    }
                    idx = end
                    if args.simulateRealtimeMs > 0 {
                        Thread.sleep(forTimeInterval: Double(args.simulateRealtimeMs) / 1000.0)
                    }
                }

                let flushed: String
                if args.deviceScope == "per-call" {
                    flushed = Device.withDefaultDevice(device) {
                        session.flush()
                    }
                } else {
                    flushed = session.flush()
                }
                if !flushed.isEmpty {
                    deltaCount += 1
                    maxGapChunks = max(maxGapChunks, gapChunks)
                    totalText += flushed
                }

                let clean = totalText.replacingOccurrences(of: "\n", with: " ")
                let wall = Date().timeIntervalSince(started)
                let audioSeconds = Double(samples.count) / 16000.0
                let realtimeFactor = audioSeconds > 0 ? wall / audioSeconds : 0
                print("[stream-file] Text chars: \(clean.count)")
                print("[stream-file] Delta count: \(deltaCount)")
                print("[stream-file] Max gap chunks: \(maxGapChunks)")
                print("[stream-file] Wall seconds: \(String(format: "%.2f", wall))")
                print("[stream-file] Audio seconds: \(String(format: "%.2f", audioSeconds))")
                print("[stream-file] Real-time factor: \(String(format: "%.3f", realtimeFactor))")
                print("SUMMARY chars=\(clean.count) deltas=\(deltaCount) max_gap_chunks=\(maxGapChunks)")
            }

            if args.deviceScope == "per-call" {
                try runInDeviceScope()
            } else {
                try Device.withDefaultDevice(device) {
                    try runInDeviceScope()
                }
            }
        } catch {
            fputs("[stream-file] ERROR: \(error)\n", stderr)
            exit(1)
        }
    }

    private struct Args {
        let audioURL: URL
        let device: String
        let language: String
        let maxTokens: Int
        let temperature: Float
        let transcriptionDelayMs: Int
        let ingestSamples: Int
        let simulateRealtimeMs: Int
        let deviceScope: String
    }

    private static func parseArgs() throws -> Args {
        var audioPath: String?
        var device = ProcessInfo.processInfo.environment["SUPERVOXTRAL_SMOKE_DEVICE"] ?? "gpu"
        var language = "auto"
        var maxTokens = 2048
        var temperature: Float = 0.0
        var delayMs = 480
        var ingestSamples = 1280
        var simulateRealtimeMs = 0
        var deviceScope = "global"

        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--audio":
                audioPath = it.next()
            case "--device":
                device = it.next() ?? device
            case "--language":
                language = it.next() ?? language
            case "--max-tokens":
                maxTokens = Int(it.next() ?? "\(maxTokens)") ?? maxTokens
            case "--temperature":
                temperature = Float(it.next() ?? "\(temperature)") ?? temperature
            case "--delay-ms":
                delayMs = Int(it.next() ?? "\(delayMs)") ?? delayMs
            case "--ingest-samples":
                ingestSamples = Int(it.next() ?? "\(ingestSamples)") ?? ingestSamples
            case "--simulate-realtime-ms":
                simulateRealtimeMs = Int(it.next() ?? "\(simulateRealtimeMs)") ?? simulateRealtimeMs
            case "--device-scope":
                deviceScope = (it.next() ?? deviceScope).lowercased()
            default:
                break
            }
        }

        guard let audioPath else {
            throw NSError(
                domain: "voxtral-stream-file",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing --audio /path/to/file.wav"]
            )
        }

        return Args(
            audioURL: URL(fileURLWithPath: audioPath),
            device: device.lowercased(),
            language: language,
            maxTokens: maxTokens,
            temperature: temperature,
            transcriptionDelayMs: delayMs,
            ingestSamples: ingestSamples,
            simulateRealtimeMs: simulateRealtimeMs,
            deviceScope: deviceScope
        )
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

    private static func loadMono16kSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "voxtral-stream-file", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate PCM buffer"])
        }
        try file.read(into: buffer)

        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0, frames > 0 else { return [] }

        var mono = [Float](repeating: 0, count: frames)

        if let data = buffer.floatChannelData {
            for c in 0..<channels {
                let ptr = data[c]
                for i in 0..<frames {
                    mono[i] += ptr[i]
                }
            }
            let inv = 1.0 / Float(channels)
            for i in 0..<frames {
                mono[i] *= inv
            }
        } else {
            throw NSError(domain: "voxtral-stream-file", code: 4, userInfo: [NSLocalizedDescriptionKey: "Audio format is not float PCM"])
        }

        let srcRate = format.sampleRate
        let dstRate = 16000.0
        if abs(srcRate - dstRate) < 0.1 {
            return mono
        }

        let duration = Double(frames) / srcRate
        let outFrames = max(1, Int(duration * dstRate))
        var out = [Float](repeating: 0, count: outFrames)

        let scale = srcRate / dstRate
        for i in 0..<outFrames {
            let srcPos = Double(i) * scale
            let lo = Int(srcPos)
            let hi = min(lo + 1, frames - 1)
            let frac = Float(srcPos - Double(lo))
            out[i] = mono[lo] * (1 - frac) + mono[hi] * frac
        }

        return out
    }
}

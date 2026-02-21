import Foundation
import MLX
import VoxtralRuntime

enum ControllerState: Equatable {
    case loading
    case idle
    case listening
    case error(String)
}

final class DictationController: @unchecked Sendable {
    var onStateChange: ((ControllerState) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onStatusDetail: ((String) -> Void)?

    private var settings: AppSettings
    private let queue = DispatchQueue(label: "supervoxtral.decode")
    private let capture = AudioCaptureEngine()
    private let injector = TextInjector()
    private var mlxDevice: Device?

    private var model: VoxtralRealtimeModel?
    private var streamingSession: VoxtralRealtimeStreamingSession?
    private var state: ControllerState = .loading
    private var isListening = false
    private var isDecoding = false
    private var timer: DispatchSourceTimer?
    private var decodeBuffer: [Float] = []
    private var emptyDecodeSamples: Int = 0
    private var committedText = ""
    private var isModelLoading = false
    private var resumeListeningAfterReload = false
    private var didInjectPrefixForSession = false
    private var didReportPrefixInjectionFailureForSession = false
    private var bufferedTranscriptBeforePrefix = ""

    private static let samplesPerToken = 1280

    private struct SendableModelBox: @unchecked Sendable {
        let model: VoxtralRealtimeModel
    }

    private enum ModelLoadError: LocalizedError {
        case timeout(seconds: Double)

        var errorDescription: String? {
            switch self {
            case .timeout(let seconds):
                return "Model load timed out after \(Int(seconds)) seconds."
            }
        }
    }

    init(settings: AppSettings) {
        self.settings = settings
        self.mlxDevice = Self.resolveDevice(settings.mlxDevice)
    }

    func updateSettings(_ newSettings: AppSettings) {
        queue.async {
            let normalized = SettingsLoader.normalizeForRuntime(newSettings)
            let oldSettings = self.settings
            self.settings = normalized

            let oldDevice = self.mlxDevice
            self.mlxDevice = Self.resolveDevice(normalized.mlxDevice)

            if self.isListening, oldSettings.decodeIntervalMs != normalized.decodeIntervalMs {
                self.restartDecodeTimerLocked()
            }

            let requiresModelReload =
                oldSettings.modelId != normalized.modelId
                || oldSettings.hfToken != normalized.hfToken
                || oldDevice != self.mlxDevice

            let requiresSessionRebuild =
                oldSettings.maxTokens != normalized.maxTokens
                || oldSettings.temperature != normalized.temperature
                || oldSettings.language != normalized.language
                || oldSettings.transcriptionDelayMs != normalized.transcriptionDelayMs
                || oldSettings.contentBias != normalized.contentBias
                || oldSettings.contentBiasStrength != normalized.contentBiasStrength
                || oldSettings.contentBiasFirstTokenFactor != normalized.contentBiasFirstTokenFactor

            if requiresModelReload {
                if self.isListening {
                    self.resumeListeningAfterReload = true
                    self.stopListeningLocked()
                }
                self.model = nil
                self.streamingSession = nil
                self.loadModelIfNeeded(force: true)
                return
            }

            if requiresSessionRebuild, let model = self.model {
                let wasListening = self.isListening
                if wasListening {
                    self.stopListeningLocked()
                }
                do {
                    self.streamingSession = try self.makeStreamingSession(for: model)
                    self.emitStatusDetail("Settings updated")
                    if wasListening {
                        self.startListeningLocked()
                    }
                } catch {
                    self.emitError("Failed to apply settings: \(error.localizedDescription)")
                    self.emitState(.error("settings"))
                }
                return
            }

            self.emitStatusDetail("Settings updated")
        }
    }

    func start() {
        loadModelIfNeeded(force: false)
    }

    func reloadModel() {
        loadModelIfNeeded(force: true)
    }

    func toggleListening() {
        queue.async {
            if self.isListening {
                self.stopListeningLocked()
            } else {
                self.startListeningLocked()
            }
        }
    }

    private func loadModelIfNeeded(force: Bool) {
        queue.async {
            if self.isModelLoading {
                return
            }
            if self.model != nil && self.streamingSession != nil && !force {
                self.emitState(.idle)
                self.emitStatusDetail("Ready")
                return
            }

            self.isModelLoading = true
            self.emitState(.loading)
            self.emitStatusDetail("Loading model")
            self.log("Loading model: \(self.settings.modelId)")

            guard let metallib = Self.findBundledMetallib() else {
                self.isModelLoading = false
                self.emitError("Missing MLX Metal library (mlx.metallib). Rebuild the app so shaders are bundled.")
                self.emitState(.error("metallib"))
                return
            }
            setenv("MLX_METAL_LIB_PATH", metallib.path, 1)

            let modelId = self.settings.modelId
            let hfToken = self.settings.hfToken
            let timeoutSeconds = max(30.0, self.settings.modelLoadTimeoutSeconds ?? 240.0)
            let mlxDevice = self.mlxDevice
            let progressHandler: @Sendable (String) -> Void = { [weak self] detail in
                DispatchQueue.main.async {
                    self?.onStatusDetail?(detail)
                }
            }

            Task {
                do {
                    let modelDir = try await VoxtralRealtimeModel.downloadPretrained(
                        modelId,
                        hfToken: hfToken,
                        progressHandler: progressHandler
                    )
                    let boxed = try await self.loadModelWithTimeout(
                        modelDir: modelDir,
                        timeoutSeconds: timeoutSeconds,
                        device: mlxDevice,
                        progressHandler: progressHandler
                    )

                    self.queue.async {
                        do {
                            let session = try self.makeStreamingSession(for: boxed.model)
                            self.model = boxed.model
                            self.streamingSession = session
                            self.isModelLoading = false
                            self.log("Model ready")
                            self.emitStatusDetail("Ready")
                            self.emitState(self.isListening ? .listening : .idle)
                            if self.resumeListeningAfterReload {
                                self.resumeListeningAfterReload = false
                                self.startListeningLocked()
                            }
                        } catch {
                            self.isModelLoading = false
                            self.model = nil
                            self.streamingSession = nil
                            self.resumeListeningAfterReload = false
                            self.emitError("Streaming runtime init failed: \(error.localizedDescription)")
                            self.emitState(.error("runtime"))
                        }
                    }
                } catch {
                    self.queue.async {
                        self.isModelLoading = false
                        self.model = nil
                        self.streamingSession = nil
                        self.resumeListeningAfterReload = false
                        self.emitError("Model load failed: \(error.localizedDescription)")
                        self.emitState(.error("model"))
                    }
                }
            }
        }
    }

    private func makeStreamingSession(for model: VoxtralRealtimeModel) throws -> VoxtralRealtimeStreamingSession {
        let params = STTGenerateParameters(
            maxTokens: settings.maxTokens,
            temperature: settings.temperature,
            topP: 1.0,
            topK: 0,
            verbose: false,
            language: settings.language,
            chunkDuration: Float(settings.contextWindowSeconds),
            minChunkDuration: 1.0
        )

        let contentBiasConfiguration = ContentBiasConfiguration(
            phrases: settings.contentBias,
            strength: settings.contentBiasStrength,
            firstTokenFactor: settings.contentBiasFirstTokenFactor
        )

        let session = VoxtralRealtimeStreamingSession(
            model: model,
            generationParameters: params,
            transcriptionDelayMs: settings.transcriptionDelayMs,
            contentBiasConfiguration: contentBiasConfiguration
        )
        if let mlxDevice {
            _ = Device.withDefaultDevice(mlxDevice) {
                session.warmup()
                return 0
            }
        } else {
            session.warmup()
        }
        return session
    }

    private func startListeningLocked() {
        guard let streamingSession else {
            emitError("Model is not ready yet.")
            if !isModelLoading {
                loadModelIfNeeded(force: false)
            }
            return
        }

        do {
            try capture.start()
        } catch {
            emitError("Microphone start failed: \(error.localizedDescription)")
            emitState(.error("microphone"))
            return
        }

        if let mlxDevice {
            _ = Device.withDefaultDevice(mlxDevice) {
                streamingSession.reset()
                return 0
            }
        } else {
            streamingSession.reset()
        }

        committedText = ""
        bufferedTranscriptBeforePrefix = ""
        didInjectPrefixForSession = settings.transcriptPrefix.isEmpty
        didReportPrefixInjectionFailureForSession = false
        decodeBuffer.removeAll(keepingCapacity: true)
        emptyDecodeSamples = 0
        isListening = true
        _ = ensurePrefixInjectedIfNeeded()
        log("Listening started")
        emitState(.listening)
        emitStatusDetail("Listening")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(max(20, settings.decodeIntervalMs)))
        timer.setEventHandler { [weak self] in
            self?.decodeTickLocked()
        }
        self.timer = timer
        timer.resume()
    }

    private func restartDecodeTimerLocked() {
        guard isListening else { return }
        timer?.cancel()
        timer = nil

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(max(20, settings.decodeIntervalMs)))
        timer.setEventHandler { [weak self] in
            self?.decodeTickLocked()
        }
        self.timer = timer
        timer.resume()
    }

    private func stopListeningLocked() {
        timer?.cancel()
        timer = nil

        let trailingAudio: [Float] = {
            let drained = capture.drainPending()
            guard !decodeBuffer.isEmpty || !drained.isEmpty else { return [] }
            if decodeBuffer.isEmpty { return drained }
            if drained.isEmpty { return decodeBuffer }
            return decodeBuffer + drained
        }()

        if let streamingSession {
            if !trailingAudio.isEmpty {
                if let mlxDevice {
                    _ = Device.withDefaultDevice(mlxDevice) {
                        streamingSession.consume(audioSamples: trailingAudio)
                    }
                } else {
                    _ = streamingSession.consume(audioSamples: trailingAudio)
                }
            }

            let flushed: String
            if let mlxDevice {
                flushed = Device.withDefaultDevice(mlxDevice) {
                    streamingSession.flush()
                }
            } else {
                flushed = streamingSession.flush()
            }
            injectDeltaIfNeeded(flushed)
        }
        flushBufferedTranscriptIfPossible()

        if !settings.transcriptSuffix.isEmpty {
            if settings.transcriptPrefix.isEmpty || didInjectPrefixForSession || ensurePrefixInjectedIfNeeded() {
                flushBufferedTranscriptIfPossible()
                injectFramingTextIfNeeded(settings.transcriptSuffix, stage: "suffix")
            } else {
                emitError("Skipping text suffix injection because prefix was not inserted.")
            }
        }

        capture.stop()
        capture.reset()
        decodeBuffer.removeAll(keepingCapacity: false)

        isListening = false
        isDecoding = false
        emptyDecodeSamples = 0
        committedText = ""
        bufferedTranscriptBeforePrefix = ""
        didInjectPrefixForSession = false
        didReportPrefixInjectionFailureForSession = false
        log("Listening stopped")

        emitStatusDetail("Ready")
        emitState(model == nil ? .loading : .idle)
    }

    private func decodeTickLocked() {
        guard isListening, !isDecoding, let streamingSession else { return }

        isDecoding = true
        defer { isDecoding = false }

        let drained = capture.drainPending()
        if !drained.isEmpty {
            decodeBuffer.append(contentsOf: drained)
        }

        let minBatch = max(Self.samplesPerToken, settings.minSamplesForDecode)
        guard decodeBuffer.count >= minBatch else { return }

        var alignedCount = (decodeBuffer.count / Self.samplesPerToken) * Self.samplesPerToken
        let maxBatch = max(minBatch, Self.samplesPerToken * 8)
        if alignedCount > maxBatch {
            alignedCount = (maxBatch / Self.samplesPerToken) * Self.samplesPerToken
        }
        guard alignedCount >= Self.samplesPerToken else { return }

        let pendingSamples: [Float]
        if alignedCount == decodeBuffer.count {
            pendingSamples = decodeBuffer
            decodeBuffer.removeAll(keepingCapacity: true)
        } else {
            pendingSamples = Array(decodeBuffer.prefix(alignedCount))
            decodeBuffer.removeFirst(alignedCount)
        }

        let delta: String
        if let mlxDevice {
            delta = Device.withDefaultDevice(mlxDevice) {
                streamingSession.consume(audioSamples: pendingSamples)
            }
        } else {
            delta = streamingSession.consume(audioSamples: pendingSamples)
        }

        if delta.isEmpty {
            emptyDecodeSamples += pendingSamples.count
            let recoveryWindow = max(12.0, settings.contextWindowSeconds)
            let recoverySamples = Int(16_000.0 * recoveryWindow)
            if emptyDecodeSamples >= recoverySamples {
                log("Streaming guard: no transcript output for \(recoveryWindow)s of audio, resetting session")
                if let mlxDevice {
                    Device.withDefaultDevice(mlxDevice) {
                        streamingSession.reset()
                    }
                } else {
                    streamingSession.reset()
                }
                emptyDecodeSamples = 0
            }
        } else {
            emptyDecodeSamples = 0
        }

        injectDeltaIfNeeded(delta)
    }

    private func injectDeltaIfNeeded(_ delta: String) {
        guard !delta.isEmpty else { return }

        if !ensurePrefixInjectedIfNeeded() {
            bufferedTranscriptBeforePrefix += delta
            return
        }

        if !bufferedTranscriptBeforePrefix.isEmpty {
            bufferedTranscriptBeforePrefix += delta
            flushBufferedTranscriptIfPossible()
            return
        }

        _ = injectTranscriptChunk(delta, bufferOnFailure: true)
    }

    private func injectFramingTextIfNeeded(_ text: String, stage: String) {
        guard !text.isEmpty else { return }
        do {
            try injector.insert(text)
        } catch {
            emitError("Text \(stage) injection failed: \(error.localizedDescription)")
        }
    }

    private func ensurePrefixInjectedIfNeeded() -> Bool {
        if didInjectPrefixForSession {
            return true
        }

        let prefix = settings.transcriptPrefix
        if prefix.isEmpty {
            didInjectPrefixForSession = true
            return true
        }

        do {
            try injector.insert(prefix)
            didInjectPrefixForSession = true
            didReportPrefixInjectionFailureForSession = false
            return true
        } catch {
            if !didReportPrefixInjectionFailureForSession {
                emitError("Text prefix injection failed: \(error.localizedDescription)")
                didReportPrefixInjectionFailureForSession = true
            }
            return false
        }
    }

    private func flushBufferedTranscriptIfPossible() {
        guard !bufferedTranscriptBeforePrefix.isEmpty else { return }
        guard ensurePrefixInjectedIfNeeded() else { return }

        let buffered = bufferedTranscriptBeforePrefix
        bufferedTranscriptBeforePrefix = ""
        _ = injectTranscriptChunk(buffered, bufferOnFailure: true)
    }

    @discardableResult
    private func injectTranscriptChunk(_ chunk: String, bufferOnFailure: Bool) -> Bool {
        guard !chunk.isEmpty else { return true }

        do {
            try injector.insert(chunk)
            committedText += chunk
            let textForUI = committedText
            DispatchQueue.main.async {
                self.onTranscript?(textForUI)
            }
            return true
        } catch {
            if bufferOnFailure {
                bufferedTranscriptBeforePrefix = chunk + bufferedTranscriptBeforePrefix
            }
            emitError("Text injection failed: \(error.localizedDescription)")
            return false
        }
    }

    private func emitState(_ newState: ControllerState) {
        state = newState
        DispatchQueue.main.async {
            self.onStateChange?(newState)
        }
    }

    private func emitError(_ message: String) {
        AppLog.write("[supervoxtral] \(message)")
        DispatchQueue.main.async {
            self.onError?(message)
        }
    }

    private func emitStatusDetail(_ message: String) {
        DispatchQueue.main.async {
            self.onStatusDetail?(message)
        }
    }

    private func loadModelWithTimeout(
        modelDir: URL,
        timeoutSeconds: Double,
        device: Device?,
        progressHandler: @escaping @Sendable (String) -> Void
    ) async throws -> SendableModelBox {
        try await withThrowingTaskGroup(of: SendableModelBox.self) { group in
            group.addTask {
                let loaded: VoxtralRealtimeModel
                if let device {
                    loaded = try Device.withDefaultDevice(device) {
                        try VoxtralRealtimeModel.fromDirectory(modelDir, progressHandler: progressHandler)
                    }
                } else {
                    loaded = try VoxtralRealtimeModel.fromDirectory(modelDir, progressHandler: progressHandler)
                }
                return SendableModelBox(model: loaded)
            }

            group.addTask {
                let nanos = UInt64(timeoutSeconds * 1_000_000_000.0)
                try await Task.sleep(nanoseconds: nanos)
                throw ModelLoadError.timeout(seconds: timeoutSeconds)
            }

            guard let first = try await group.next() else {
                throw ModelLoadError.timeout(seconds: timeoutSeconds)
            }
            group.cancelAll()
            return first
        }
    }

    private static func resolveDevice(_ rawValue: String?) -> Device? {
        guard let rawValue else { return nil }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "cpu":
            return .cpu
        case "gpu":
            return .gpu
        default:
            return nil
        }
    }

    private static func findBundledMetallib() -> URL? {
        let fm = FileManager.default
        guard let exeURL = Bundle.main.executableURL else { return nil }
        let exeDir = exeURL.deletingLastPathComponent()

        let candidates = [
            exeDir.appendingPathComponent("mlx.metallib"),
            exeDir.appendingPathComponent("default.metallib"),
            exeDir.appendingPathComponent("Resources/default.metallib"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mlx.metallib"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/default.metallib"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/default.metallib"),
        ]

        for path in candidates where fm.fileExists(atPath: path.path) {
            return path
        }
        return nil
    }

    private func log(_ message: String) {
        AppLog.write("[supervoxtral] \(message)")
    }
}

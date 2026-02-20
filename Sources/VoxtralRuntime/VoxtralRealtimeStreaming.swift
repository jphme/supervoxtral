import Foundation
import MLX
import MLXFFT
import MLXNN

private enum VoxtralStreamingConstants {
    static let sampleRate = 16000
    static let hopLength = 160
    static let samplesPerToken = 1280 // hopLength * conv2Stride(2) * downsample(4)
}

public final class VoxtralRealtimeStreamingSession {
    private let model: VoxtralRealtimeModel
    private let temperature: Float
    private let maxTokens: Int
    private var contentBiasProcessor: ContentBiasProcessor?

    private let nLeftPadTokens: Int
    private let nRightPadTokens: Int
    private let prefixLength: Int
    private let eosTokenId: Int

    private let melFilters: MLXArray
    private let stftWindow: MLXArray
    private let promptTextEmbeds: MLXArray

    private var audioTail: [Float]?
    private var conv1Tail: MLXArray?
    private var conv2Tail: MLXArray?
    private var encoderCache: [VoxtralRealtimeEncoderKVCache?]
    private var encoderPositionOffset: Int = 0
    private var downsampleBuffer: MLXArray?

    private var pendingAudio: [Float] = []
    private var audioEmbeds: MLXArray?
    private var nAudioSamplesFed: Int = 0
    private var nTotalDecoded: Int = 0

    private var prefilled = false
    private var decoderCache: [VoxtralRealtimeDecoderKVCache?]?
    private var pendingToken: MLXArray?
    private var decoderEvalCounter: Int = 0
    private var generatedTokenCount: Int = 0

    private var firstCycle = true

    public init(
        model: VoxtralRealtimeModel,
        generationParameters: STTGenerateParameters,
        transcriptionDelayMs: Int? = nil,
        contentBiasConfiguration: ContentBiasConfiguration? = nil
    ) {
        self.model = model
        self.temperature = generationParameters.temperature
        self.maxTokens = generationParameters.maxTokens
        self.contentBiasProcessor = model.makeContentBiasProcessor(configuration: contentBiasConfiguration)

        let delayTokens = Self.numDelayTokens(
            delayMs: transcriptionDelayMs ?? model.config.transcriptionDelayMs,
            sampleRate: VoxtralStreamingConstants.sampleRate,
            hopLength: VoxtralStreamingConstants.hopLength,
            audioLengthPerToken: 8
        )
        nLeftPadTokens = model.config.nLeftPadTokens
        nRightPadTokens = (delayTokens + 1) + 10
        prefixLength = 1 + nLeftPadTokens + delayTokens
        eosTokenId = model.config.eosTokenId

        let audioArgs = model.config.audioEncodingArgs
        melFilters = VoxtralRealtimeAudio.computeMelFilters(
            numMelBins: audioArgs.numMelBins,
            windowSize: audioArgs.windowSize,
            sampleRate: audioArgs.samplingRate
        ).asType(.float32)

        let n = MLXArray(0..<audioArgs.windowSize).asType(.float32)
        stftWindow = 0.5 * (1.0 - cos((2.0 * Float.pi * n) / Float(audioArgs.windowSize)))

        let promptIds = [model.config.bosTokenId]
            + Array(repeating: model.config.streamingPadTokenId, count: nLeftPadTokens + delayTokens)
        let promptIdsMX = MLXArray(promptIds.map(Int32.init))
        promptTextEmbeds = model.decoder.embedTokens(promptIdsMX)

        encoderCache = Array(repeating: nil, count: model.encoder.transformerLayers.count)

        eval(melFilters, stftWindow, promptTextEmbeds)
    }

    public func warmup() {
        let warmupSamples = Array(
            repeating: Float(0),
            count: (nLeftPadTokens + 10) * VoxtralStreamingConstants.samplesPerToken
        )
        _ = consume(audioSamples: warmupSamples)
        _ = flush()
        reset()
    }

    public func reset() {
        audioTail = nil
        conv1Tail = nil
        conv2Tail = nil
        encoderCache = Array(repeating: nil, count: model.encoder.transformerLayers.count)
        encoderPositionOffset = 0
        downsampleBuffer = nil

        pendingAudio.removeAll(keepingCapacity: true)
        audioEmbeds = nil
        nAudioSamplesFed = 0
        nTotalDecoded = 0

        prefilled = false
        decoderCache = nil
        pendingToken = nil
        decoderEvalCounter = 0
        generatedTokenCount = 0
        firstCycle = true
        contentBiasProcessor?.reset()
    }

    public func consume(audioSamples: [Float]) -> String {
        if !audioSamples.isEmpty {
            pendingAudio.append(contentsOf: audioSamples)
            processPendingAlignedAudio()
        }

        prefillIfNeeded()

        let safeTotal = nLeftPadTokens + nAudioSamplesFed / VoxtralStreamingConstants.samplesPerToken
        return decodeAvailable(safeTotal: safeTotal)
    }

    public func flush() -> String {
        var flushed = ""

        var flushChunk = pendingAudio
        pendingAudio.removeAll(keepingCapacity: true)

        if !flushChunk.isEmpty || prefilled || pendingToken != nil {
            flushChunk.append(contentsOf: Array(
                repeating: Float(0),
                count: nRightPadTokens * VoxtralStreamingConstants.samplesPerToken
            ))

            processRawAudioChunk(flushChunk, includeLeftPadOnFirstCycle: true)
            prefillIfNeeded()
            flushed += decodeAvailable(safeTotal: nil)

            if let pendingToken {
                let tokenId = pendingToken.item(Int.self)
                if tokenId != eosTokenId {
                    flushed += model.decodeToken(tokenId: tokenId)
                }
            }
        }

        reset()
        return flushed
    }
}

private extension VoxtralRealtimeStreamingSession {
    func processPendingAlignedAudio() {
        let nFeed = (pendingAudio.count / VoxtralStreamingConstants.samplesPerToken) * VoxtralStreamingConstants.samplesPerToken
        guard nFeed > 0 else { return }

        var chunk = Array(pendingAudio.prefix(nFeed))
        pendingAudio.removeFirst(nFeed)
        nAudioSamplesFed += nFeed

        if firstCycle {
            chunk.insert(
                contentsOf: Array(
                    repeating: Float(0),
                    count: nLeftPadTokens * VoxtralStreamingConstants.samplesPerToken
                ),
                at: 0
            )
            firstCycle = false
        }

        processRawAudioChunk(chunk, includeLeftPadOnFirstCycle: false)
    }

    func processRawAudioChunk(_ chunk: [Float], includeLeftPadOnFirstCycle: Bool) {
        guard !chunk.isEmpty else { return }

        var inputChunk = chunk
        if includeLeftPadOnFirstCycle, firstCycle {
            inputChunk.insert(
                contentsOf: Array(
                    repeating: Float(0),
                    count: nLeftPadTokens * VoxtralStreamingConstants.samplesPerToken
                ),
                at: 0
            )
            firstCycle = false
        }

        let melStep = computeMelStep(inputChunk: inputChunk)
        audioTail = melStep.newTail

        if melStep.mel.shape[1] == 0 {
            return
        }

        guard let newEmbeds = encodeStep(newMel: melStep.mel) else {
            return
        }

        eval(newEmbeds)
        if let existing = audioEmbeds {
            audioEmbeds = MLX.concatenated([existing, newEmbeds], axis: 0)
            if let audioEmbeds {
                eval(audioEmbeds)
            }
        } else {
            audioEmbeds = newEmbeds
        }
    }

    func computeMelStep(inputChunk: [Float]) -> (mel: MLXArray, newTail: [Float]) {
        let audioArgs = model.config.audioEncodingArgs
        let tailLength = audioArgs.windowSize - audioArgs.hopLength

        let combined: [Float]
        if let audioTail {
            combined = audioTail + inputChunk
        } else {
            let leftPad = Array(repeating: Float(0), count: audioArgs.windowSize / 2)
            combined = leftPad + inputChunk
        }

        let newTail: [Float]
        if combined.count <= tailLength {
            newTail = combined
        } else {
            newTail = Array(combined.suffix(tailLength))
        }

        if combined.count < audioArgs.windowSize {
            return (MLXArray.zeros([audioArgs.numMelBins, 0], type: Float.self), newTail)
        }

        let audio = MLXArray(combined).asType(.float32)
        let nFrames = 1 + (audio.shape[0] - audioArgs.windowSize) / audioArgs.hopLength

        if nFrames <= 0 {
            return (MLXArray.zeros([audioArgs.numMelBins, 0], type: Float.self), newTail)
        }

        let frames = asStrided(
            audio,
            [nFrames, audioArgs.windowSize],
            strides: [audioArgs.hopLength, 1],
            offset: 0
        )
        let windowed = frames * stftWindow.expandedDimensions(axis: 0)

        let spectrum = MLXFFT.rfft(windowed, axis: -1)
        let magnitudes = MLX.abs(spectrum).square() // [frames, n_freq]

        var melSpec = MLX.matmul(magnitudes, melFilters) // [frames, n_mels]
        melSpec = MLX.maximum(melSpec, MLXArray(Float(1e-10)))

        var logSpec = MLX.log10(melSpec)
        let minVal = audioArgs.globalLogMelMax - 8.0
        logSpec = MLX.maximum(logSpec, MLXArray(minVal))
        logSpec = (logSpec + MLXArray(Float(4.0))) / MLXArray(Float(4.0))

        return (logSpec.transposed(1, 0), newTail)
    }

    func encodeStep(newMel: MLXArray) -> MLXArray? {
        let melTime = newMel.transposed(1, 0).expandedDimensions(axis: 0) // [1, T, n_mels]
        let conv1Pad = model.encoder.convLayers0Conv.padding
        let conv2Pad = model.encoder.convLayers1Conv.padding

        let conv1Input: MLXArray
        if let conv1Tail {
            conv1Input = MLX.concatenated([conv1Tail, melTime], axis: 1)
        } else {
            conv1Input = MLX.padded(
                melTime,
                widths: [IntOrPair(0), IntOrPair((conv1Pad, 0)), IntOrPair(0)]
            )
        }

        let melFrames = melTime.shape[1]
        if melFrames >= conv1Pad {
            conv1Tail = melTime[0..., (melFrames - conv1Pad)..<melFrames, 0...]
        } else {
            conv1Tail = melTime
        }

        var conv1 = gelu(model.encoder.convLayers0Conv.conv(conv1Input))

        let conv2Input: MLXArray
        if let conv2Tail {
            conv2Input = MLX.concatenated([conv2Tail, conv1], axis: 1)
        } else {
            conv2Input = MLX.padded(
                conv1,
                widths: [IntOrPair(0), IntOrPair((conv2Pad, 0)), IntOrPair(0)]
            )
        }

        let conv1Frames = conv1.shape[1]
        if conv1Frames >= conv2Pad {
            conv2Tail = conv1[0..., (conv1Frames - conv2Pad)..<conv1Frames, 0...]
        } else {
            conv2Tail = conv1
        }

        conv1 = gelu(model.encoder.convLayers1Conv.conv(conv2Input))

        if conv1.shape[1] == 0 {
            return nil
        }

        var x = conv1.squeezed(axis: 0)
        let positions = MLXArray(encoderPositionOffset..<(encoderPositionOffset + x.shape[0])).asType(.int32)
        encoderPositionOffset += x.shape[0]

        for i in model.encoder.transformerLayers.indices {
            let next = model.encoder.transformerLayers[i](x, positions: positions, cache: encoderCache[i])
            x = next.0
            encoderCache[i] = next.1
        }

        x = model.encoder.transformerNorm(x)

        if let downsampleBuffer {
            x = MLX.concatenated([downsampleBuffer, x], axis: 0)
            eval(x)
        }

        let ds = model.config.encoderArgs.downsampleFactor
        let nComplete = (x.shape[0] / ds) * ds

        if nComplete == 0 {
            downsampleBuffer = x
            eval(x)
            evaluateEncoderCache()
            return nil
        }

        if x.shape[0] > nComplete {
            downsampleBuffer = x[nComplete..., 0...]
            if let downsampleBuffer {
                eval(downsampleBuffer)
            }
        } else {
            downsampleBuffer = nil
        }

        var grouped = x[0..<nComplete, 0...].reshaped(nComplete / ds, model.config.encoderArgs.dim * ds)
        grouped = gelu(model.encoder.audioLanguageProjection0(grouped))
        let embeds = model.encoder.audioLanguageProjection2(grouped)

        evaluateEncoderCache()
        return embeds
    }

    func evaluateEncoderCache() {
        var arrays: [MLXArray] = []
        arrays.reserveCapacity(encoderCache.count * 2)
        for cache in encoderCache {
            if let cache {
                arrays.append(cache.keys)
                arrays.append(cache.values)
            }
        }
        if !arrays.isEmpty {
            eval(arrays)
        }
    }

    func prefillIfNeeded() {
        guard !prefilled, let audioEmbeds else {
            return
        }
        guard nTotalDecoded + audioEmbeds.shape[0] >= prefixLength else {
            return
        }

        let prefixAudio = audioEmbeds[0..<prefixLength, 0...]
        let prefixEmbeds = prefixAudio + promptTextEmbeds

        let prefill = model.decoder(prefixEmbeds, startPos: 0, cache: nil)
        decoderCache = prefill.1

        let logits = model.decoder.logits(prefill.0[prefill.0.shape[0] - 1])
        var evalArrays: [MLXArray] = [logits]
        for cache in prefill.1 {
            if let cache {
                evalArrays.append(cache.keys)
                evalArrays.append(cache.values)
            }
        }
        eval(evalArrays)

        pendingToken = sampleArray(logits: logits)
        if let pendingToken {
            asyncEval(pendingToken)
        }
        decoderEvalCounter = 0
        generatedTokenCount = 0

        trimAudioEmbeds(consumed: prefixLength)
        nTotalDecoded = prefixLength
        prefilled = true
    }

    func decodeAvailable(safeTotal: Int?) -> String {
        guard prefilled, let audioEmbeds else {
            return ""
        }

        let nToDecode: Int
        if let safeTotal {
            nToDecode = min(audioEmbeds.shape[0], safeTotal - nTotalDecoded)
        } else {
            nToDecode = audioEmbeds.shape[0]
        }

        guard nToDecode > 0 else {
            return ""
        }

        let step = decodeSteps(embeds: audioEmbeds, nToDecode: nToDecode)
        nTotalDecoded += step.consumed
        trimAudioEmbeds(consumed: step.consumed)

        if step.hitEOS {
            resetForNextUtterance()
        }

        return step.delta
    }

    func decodeSteps(embeds: MLXArray, nToDecode: Int) -> (consumed: Int, delta: String, hitEOS: Bool) {
        var delta = ""

        for i in 0..<nToDecode {
            guard let pendingToken else {
                return (i, delta, true)
            }

            let tokenId = pendingToken.item(Int.self)
            if tokenId == eosTokenId || generatedTokenCount >= maxTokens {
                decoderCache = nil
                self.pendingToken = nil
                contentBiasProcessor?.reset()
                return (i, delta, true)
            }

            let text = model.decodeToken(tokenId: tokenId)
            if !text.isEmpty {
                delta += text
            }
            contentBiasProcessor?.update(tokenId: tokenId)

            let tokenEmbed = model.decoder.embedToken(tokenId: tokenId)
            let inputEmbed = (embeds[i] + tokenEmbed).expandedDimensions(axis: 0)
            let startPos = nTotalDecoded + i

            let next = model.decoder(inputEmbed, startPos: startPos, cache: decoderCache)
            decoderCache = next.1

            let logits = model.decoder.logits(next.0[0])
            let biasedLogits: MLXArray
            if let contentBiasProcessor, contentBiasProcessor.hasBias {
                biasedLogits = contentBiasProcessor.apply(logits: logits)
            } else {
                biasedLogits = logits
            }
            let nextToken = sampleArray(logits: biasedLogits)
            asyncEval(nextToken)
            self.pendingToken = nextToken

            generatedTokenCount += 1
            decoderEvalCounter += 1
            if decoderEvalCounter >= 16 {
                evaluateDecoderCache()
                decoderEvalCounter = 0
            }
            if generatedTokenCount % 128 == 0 {
                Memory.clearCache()
            }
        }

        return (nToDecode, delta, false)
    }

    func trimAudioEmbeds(consumed: Int) {
        guard consumed > 0, let audioEmbeds else {
            return
        }

        if audioEmbeds.shape[0] > consumed {
            let trimmed = audioEmbeds[consumed..., 0...]
            self.audioEmbeds = trimmed
            eval(trimmed)
        } else {
            self.audioEmbeds = nil
        }
    }

    func resetForNextUtterance() {
        audioTail = nil
        conv1Tail = nil
        conv2Tail = nil
        encoderCache = Array(repeating: nil, count: model.encoder.transformerLayers.count)
        encoderPositionOffset = 0
        downsampleBuffer = nil

        pendingAudio.removeAll(keepingCapacity: true)
        audioEmbeds = nil
        nAudioSamplesFed = 0
        nTotalDecoded = 0

        prefilled = false
        decoderCache = nil
        pendingToken = nil
        decoderEvalCounter = 0
        generatedTokenCount = 0
        firstCycle = true
        contentBiasProcessor?.reset()
    }

    func evaluateDecoderCache() {
        guard let decoderCache else { return }

        var arrays: [MLXArray] = []
        arrays.reserveCapacity(decoderCache.count * 2)
        for cache in decoderCache {
            if let cache {
                arrays.append(cache.keys)
                arrays.append(cache.values)
            }
        }
        if !arrays.isEmpty {
            eval(arrays)
        }
    }

    func sampleArray(logits: MLXArray) -> MLXArray {
        let logits1D: MLXArray
        if logits.ndim > 1 {
            logits1D = logits.squeezed()
        } else {
            logits1D = logits
        }

        if temperature <= 0 {
            return logits1D.argMax(axis: -1)
        }

        let scaled = (logits1D / temperature).expandedDimensions(axis: 0)
        return categorical(scaled).squeezed()
    }

    static func numDelayTokens(delayMs: Int, sampleRate: Int, hopLength: Int, audioLengthPerToken: Int) -> Int {
        let delayLength = Int(Double(delayMs) / 1000.0 * Double(sampleRate))

        let frames: Int
        if delayLength % hopLength != 0 {
            frames = Int(ceil(Double(delayLength) / Double(hopLength) - 1.0))
        } else {
            frames = delayLength / hopLength
        }

        return Int(ceil(Double(frames) / Double(audioLengthPerToken)))
    }
}

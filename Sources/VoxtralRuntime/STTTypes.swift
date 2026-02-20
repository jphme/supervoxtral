import Foundation
import MLX

public struct STTGenerateParameters: Sendable {
    public let maxTokens: Int
    public let temperature: Float
    public let topP: Float
    public let topK: Int
    public let verbose: Bool
    public let language: String
    public let chunkDuration: Float
    public let minChunkDuration: Float

    public init(
        maxTokens: Int = 8192,
        temperature: Float = 0.0,
        topP: Float = 0.95,
        topK: Int = 0,
        verbose: Bool = false,
        language: String = "English",
        chunkDuration: Float = 1200.0,
        minChunkDuration: Float = 1.0
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.verbose = verbose
        self.language = language
        self.chunkDuration = chunkDuration
        self.minChunkDuration = minChunkDuration
    }
}

public protocol STTGenerationModel: AnyObject {
    var defaultGenerationParameters: STTGenerateParameters { get }

    func generate(audio: MLXArray, generationParameters: STTGenerateParameters) -> STTOutput
    func generateStream(
        audio: MLXArray,
        generationParameters: STTGenerateParameters
    ) -> AsyncThrowingStream<STTGeneration, Error>
}

public extension STTGenerationModel {
    func generate(audio: MLXArray, generationParameters: STTGenerateParameters? = nil) -> STTOutput {
        generate(audio: audio, generationParameters: generationParameters ?? defaultGenerationParameters)
    }

    func generateStream(
        audio: MLXArray,
        generationParameters: STTGenerateParameters? = nil
    ) -> AsyncThrowingStream<STTGeneration, Error> {
        generateStream(audio: audio, generationParameters: generationParameters ?? defaultGenerationParameters)
    }
}

public enum STTGeneration: Sendable {
    case token(String)
    case info(STTGenerationInfo)
    case result(STTOutput)
}

public struct STTGenerationInfo: Sendable {
    public let promptTokenCount: Int
    public let generationTokenCount: Int
    public let prefillTime: TimeInterval
    public let generateTime: TimeInterval
    public let tokensPerSecond: Double
    public let peakMemoryUsage: Double

    public init(
        promptTokenCount: Int,
        generationTokenCount: Int,
        prefillTime: TimeInterval,
        generateTime: TimeInterval,
        tokensPerSecond: Double,
        peakMemoryUsage: Double
    ) {
        self.promptTokenCount = promptTokenCount
        self.generationTokenCount = generationTokenCount
        self.prefillTime = prefillTime
        self.generateTime = generateTime
        self.tokensPerSecond = tokensPerSecond
        self.peakMemoryUsage = peakMemoryUsage
    }
}

public struct STTOutput: @unchecked Sendable {
    public let text: String
    public let segments: [[String: Any]]?
    public let language: String?
    public let promptTokens: Int
    public let generationTokens: Int
    public let totalTokens: Int
    public let promptTps: Double
    public let generationTps: Double
    public let totalTime: Double
    public let peakMemoryUsage: Double

    public init(
        text: String,
        segments: [[String: Any]]? = nil,
        language: String? = nil,
        promptTokens: Int = 0,
        generationTokens: Int = 0,
        totalTokens: Int = 0,
        promptTps: Double = 0.0,
        generationTps: Double = 0.0,
        totalTime: Double = 0.0,
        peakMemoryUsage: Double = 0.0
    ) {
        self.text = text
        self.segments = segments
        self.language = language
        self.promptTokens = promptTokens
        self.generationTokens = generationTokens
        self.totalTokens = totalTokens
        self.promptTps = promptTps
        self.generationTps = generationTps
        self.totalTime = totalTime
        self.peakMemoryUsage = peakMemoryUsage
    }
}

import Foundation
import Testing
@testable import VoxtralRuntime

private enum ContentBiasTestError: Error {
    case tokenizationFailed
}

@Suite("ContentBias")
struct ContentBiasProcessorTests {
    @Test
    func firstTokenBoostAppliesWhenNoMatchInProgress() throws {
        let tokenizer = try makeTokenizer()
        guard let phraseTokens = tokenizer.encode(text: " foobar"),
              let firstToken = phraseTokens.first
        else {
            throw ContentBiasTestError.tokenizationFailed
        }

        let processor = ContentBiasProcessor(
            configuration: ContentBiasConfiguration(phrases: ["foobar"], strength: 5.0, firstTokenFactor: 0.2),
            tokenizer: tokenizer,
            eosTokenId: 15
        )

        var logits = [Float](repeating: 0, count: 16)
        logits[1] = 3
        logits[15] = -10

        let deltas = try #require(processor.biasDeltas(for: logits))
        #expect(abs(deltas[firstToken] - 1.0) < 1e-5)
        #expect(abs(deltas[1]) < 1e-5)
    }

    @Test
    func continuationBoostTargetsMaxPlusStrength() throws {
        let tokenizer = try makeTokenizer()
        guard let phraseTokens = tokenizer.encode(text: " foobar"), phraseTokens.count >= 2 else {
            throw ContentBiasTestError.tokenizationFailed
        }

        let firstToken = phraseTokens[0]
        let continuationToken = phraseTokens[1]

        let processor = ContentBiasProcessor(
            configuration: ContentBiasConfiguration(phrases: ["foobar"], strength: 5.0, firstTokenFactor: 0.2),
            tokenizer: tokenizer,
            eosTokenId: 15
        )

        processor.update(tokenId: firstToken)

        var logits = [Float](repeating: -20, count: 16)
        let competingToken = (0..<logits.count).first { $0 != continuationToken && $0 != 15 } ?? 0
        logits[competingToken] = 4
        logits[15] = -100
        logits[continuationToken] = -25

        let deltas = try #require(processor.biasDeltas(for: logits))
        #expect(abs(deltas[continuationToken] - 34.0) < 1e-4)
        #expect(abs(deltas[competingToken]) < 1e-4)
    }

    @Test
    func eosGuardSkipsBias() throws {
        let tokenizer = try makeTokenizer()
        let processor = ContentBiasProcessor(
            configuration: ContentBiasConfiguration(phrases: ["foobar"], strength: 5.0, firstTokenFactor: 0.2),
            tokenizer: tokenizer,
            eosTokenId: 15
        )

        var logits = [Float](repeating: 0, count: 16)
        logits[1] = 10
        logits[15] = 7

        #expect(processor.biasDeltas(for: logits) == nil)
    }
}

private extension ContentBiasProcessorTests {
    func makeTokenizer() throws -> VoxtralRealtimeTokenizer {
        let tokens: [[UInt8]] = [
            [32],
            [102],
            [111],
            [98],
            [97],
            [114],
            [32, 102, 111, 111],
            [98, 97, 114],
        ]

        var vocab: [[String: Any]] = []
        for (rank, bytes) in tokens.enumerated() {
            vocab.append([
                "rank": rank,
                "token_bytes": Data(bytes).base64EncodedString(),
            ])
        }

        let payload: [String: Any] = [
            "config": [
                "default_num_special_tokens": 0,
            ],
            "vocab": vocab,
            "special_tokens": [],
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("tekken.json")
        try data.write(to: fileURL)

        return try VoxtralRealtimeTokenizer(tekkenURL: fileURL)
    }
}

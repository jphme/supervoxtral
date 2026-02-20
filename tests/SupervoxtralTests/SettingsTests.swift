import Foundation
import Testing
@testable import supervoxtral

@Suite("Settings")
struct SettingsTests {
    @Test
    func settingsDecodeAcceptsContextBiasAliases() throws {
        let json = """
        {
          "modelId": "ellamind/Voxtral-Mini-4B-Realtime-8bit-mlx",
          "context_bias": ["ellamind", "JAAI"],
          "context_bias_strength": 5.0,
          "context_bias_first_token_factor": 0.25,
          "prefix": "<transcription>",
          "suffix": "</transcription>"
        }
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        #expect(decoded.contentBias == ["ellamind", "JAAI"])
        #expect(abs(decoded.contentBiasStrength - 5.0) < 1e-5)
        #expect(abs(decoded.contentBiasFirstTokenFactor - 0.25) < 1e-5)
        #expect(decoded.transcriptPrefix == "<transcription>")
        #expect(decoded.transcriptSuffix == "</transcription>")
    }

    @Test
    func normalizeForRuntimeCleansBiasValues() {
        var settings = AppSettings.default
        settings.contentBias = ["", "  ellamind ", "JAAI", "   "]
        settings.contentBiasStrength = -1
        settings.contentBiasFirstTokenFactor = 1.5

        let normalized = SettingsLoader.normalizeForRuntime(settings)

        #expect(normalized.contentBias == ["ellamind", "JAAI"])
        #expect(abs(normalized.contentBiasStrength - 5.0) < 1e-5)
        #expect(abs(normalized.contentBiasFirstTokenFactor - 1.0) < 1e-5)
    }
}

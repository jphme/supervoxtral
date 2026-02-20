import Foundation
import Testing
@testable import VoxtralRuntime

@Suite("Tokenizer Parity")
struct TokenizerParityTests {
    @Test
    func tokenizerMatchesKnownTekkenEncodings() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tekkenURL = home
            .appendingPathComponent("Library/Caches/supervoxtral", isDirectory: true)
            .appendingPathComponent("ellamind_Voxtral-Mini-4B-Realtime-8bit-mlx", isDirectory: true)
            .appendingPathComponent("tekken.json")

        guard FileManager.default.fileExists(atPath: tekkenURL.path) else {
            // Local dev machine may not have the model cached yet.
            return
        }

        let tokenizer = try VoxtralRealtimeTokenizer(tekkenURL: tekkenURL)

        #expect(tokenizer.encode(text: " ellamind") == [10771, 1325, 1629])
        #expect(tokenizer.encode(text: " Ellamind") == [9991, 1325, 1629])
        #expect(tokenizer.encode(text: " JAAI") == [1507, 14229, 1073])
        #expect(tokenizer.encode(text: " jaai") == [4042, 2464])
        #expect(tokenizer.encode(text: " elluminate") == [10771, 21087])
        #expect(tokenizer.encode(text: " Elluminate") == [9991, 21087])
    }
}

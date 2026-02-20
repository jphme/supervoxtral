import Foundation

struct VoxtralRealtimeTekkenFile: Decodable {
    struct Config: Decodable {
        let defaultNumSpecialTokens: Int?
        let pattern: String?

        enum CodingKeys: String, CodingKey {
            case defaultNumSpecialTokens = "default_num_special_tokens"
            case pattern
        }
    }

    struct SpecialToken: Decodable {
        let rank: Int?
    }

    struct VocabEntry: Decodable {
        let rank: Int?
        let tokenBytes: String

        enum CodingKeys: String, CodingKey {
            case rank
            case tokenBytes = "token_bytes"
        }
    }

    let vocab: [VocabEntry]
    let config: Config?
    let specialTokens: [SpecialToken]?

    enum CodingKeys: String, CodingKey {
        case vocab
        case config
        case specialTokens = "special_tokens"
    }
}

final class VoxtralRealtimeTokenizer {
    let vocab: [VoxtralRealtimeTekkenFile.VocabEntry]
    let nSpecial: Int
    let specialIds: Set<Int>

    private let tokenPattern: NSRegularExpression?
    private var bytesCache: [Int: [UInt8]] = [:]
    private var mergeableRanks: [Data: Int]?

    init(tekkenURL: URL) throws {
        let data = try Data(contentsOf: tekkenURL)
        let parsed = try JSONDecoder().decode(VoxtralRealtimeTekkenFile.self, from: data)
        vocab = parsed.vocab
        nSpecial = parsed.config?.defaultNumSpecialTokens ?? 1000
        specialIds = Set((parsed.specialTokens ?? []).compactMap { $0.rank })
        if let pattern = parsed.config?.pattern, !pattern.isEmpty {
            tokenPattern = try? NSRegularExpression(pattern: pattern)
        } else {
            tokenPattern = nil
        }
    }

    static func fromModelDirectory(_ modelDir: URL) throws -> VoxtralRealtimeTokenizer {
        let tekkenURL = modelDir.appendingPathComponent("tekken.json")
        guard FileManager.default.fileExists(atPath: tekkenURL.path) else {
            throw NSError(
                domain: "VoxtralRealtimeTokenizer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "tekken.json not found at \(modelDir.path)"]
            )
        }
        return try VoxtralRealtimeTokenizer(tekkenURL: tekkenURL)
    }

    func decode(tokenIds: [Int]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(tokenIds.count * 2)

        for tokenId in tokenIds {
            guard tokenId >= 0 else { continue }
            if tokenId < nSpecial || specialIds.contains(tokenId) {
                continue
            }
            out.append(contentsOf: tokenBytes(for: tokenId))
        }

        return String(decoding: out, as: UTF8.self)
    }

    func encode(text: String) -> [Int]? {
        guard !text.isEmpty else { return [] }

        var tokenIDs: [Int] = []
        for segment in tokenizeForEncoding(text) {
            guard let encoded = encodeSegment(bytes: Array(segment.utf8)) else {
                return nil
            }
            tokenIDs.append(contentsOf: encoded)
        }
        return tokenIDs
    }

    private func tokenizeForEncoding(_ text: String) -> [String] {
        guard let tokenPattern else { return [text] }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = tokenPattern.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return [text] }

        var parts: [String] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let gap = NSRange(location: cursor, length: match.range.location - cursor)
                parts.append(nsText.substring(with: gap))
            }
            if match.range.length > 0 {
                parts.append(nsText.substring(with: match.range))
            }
            cursor = match.range.location + match.range.length
        }

        if cursor < nsText.length {
            parts.append(nsText.substring(from: cursor))
        }

        return parts.filter { !$0.isEmpty }
    }

    private func encodeSegment(bytes: [UInt8]) -> [Int]? {
        guard !bytes.isEmpty else { return [] }
        let ranks = buildMergeableRanks()

        // tiktoken-style byte pair encoding:
        // start from raw bytes and repeatedly merge the adjacent pair with the
        // best (lowest) merge rank until no valid merge remains.
        var parts = bytes.map { Data([$0]) }
        if parts.count == 1 {
            guard let rank = ranks[parts[0]] else { return nil }
            return [nSpecial + rank]
        }

        while parts.count > 1 {
            var bestPairIndex: Int?
            var bestPairRank = Int.max

            for i in 0..<(parts.count - 1) {
                var merged = Data()
                merged.reserveCapacity(parts[i].count + parts[i + 1].count)
                merged.append(parts[i])
                merged.append(parts[i + 1])

                if let rank = ranks[merged], rank < bestPairRank {
                    bestPairRank = rank
                    bestPairIndex = i
                }
            }

            guard let mergeIndex = bestPairIndex else {
                break
            }

            var merged = Data()
            merged.reserveCapacity(parts[mergeIndex].count + parts[mergeIndex + 1].count)
            merged.append(parts[mergeIndex])
            merged.append(parts[mergeIndex + 1])
            parts[mergeIndex] = merged
            parts.remove(at: mergeIndex + 1)
        }

        var output: [Int] = []
        output.reserveCapacity(parts.count)
        for piece in parts {
            guard let rank = ranks[piece] else {
                return nil
            }
            output.append(nSpecial + rank)
        }
        return output
    }

    private func buildMergeableRanks() -> [Data: Int] {
        if let mergeableRanks {
            return mergeableRanks
        }

        var map: [Data: Int] = [:]
        map.reserveCapacity(vocab.count)

        for index in vocab.indices {
            let tokenId = nSpecial + index
            let bytes = tokenBytes(for: tokenId)
            guard !bytes.isEmpty else { continue }
            let rank = vocab[index].rank ?? index
            map[Data(bytes)] = rank
        }

        mergeableRanks = map
        return map
    }

    private func tokenBytes(for tokenId: Int) -> [UInt8] {
        if let cached = bytesCache[tokenId] {
            return cached
        }

        guard tokenId >= nSpecial, !specialIds.contains(tokenId) else {
            bytesCache[tokenId] = []
            return []
        }

        let vocabId = tokenId - nSpecial
        guard vocabId >= 0, vocabId < vocab.count else {
            bytesCache[tokenId] = []
            return []
        }

        let entry = vocab[vocabId]
        let decoded = Data(base64Encoded: entry.tokenBytes) ?? Data()
        let bytes = [UInt8](decoded)
        bytesCache[tokenId] = bytes
        return bytes
    }
}

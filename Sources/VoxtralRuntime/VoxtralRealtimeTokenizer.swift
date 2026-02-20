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
    private struct EncodingCandidate {
        let tokenId: Int
        let rank: Int
        let bytes: [UInt8]
    }

    let vocab: [VoxtralRealtimeTekkenFile.VocabEntry]
    let nSpecial: Int
    let specialIds: Set<Int>

    private let tokenPattern: NSRegularExpression?
    private var bytesCache: [Int: [UInt8]] = [:]
    private var encodingCandidatesByFirstByte: [UInt8: [EncodingCandidate]]?

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
        let candidates = buildEncodingCandidatesByFirstByte()
        let n = bytes.count

        var bestTokenCount = Array(repeating: Int.max, count: n + 1)
        var bestRankSum = Array(repeating: Int.max, count: n + 1)
        var nextIndex = Array(repeating: -1, count: n)
        var nextTokenID = Array(repeating: -1, count: n)

        bestTokenCount[n] = 0
        bestRankSum[n] = 0

        for i in stride(from: n - 1, through: 0, by: -1) {
            guard let segmentCandidates = candidates[bytes[i]] else { continue }

            for candidate in segmentCandidates {
                let end = i + candidate.bytes.count
                guard end <= n else { continue }
                guard bestTokenCount[end] != Int.max else { continue }
                guard bytes[i..<end].elementsEqual(candidate.bytes) else { continue }

                let tokenCount = bestTokenCount[end] + 1
                let rankSum = bestRankSum[end] == Int.max ? Int.max : bestRankSum[end] + candidate.rank

                if tokenCount < bestTokenCount[i]
                    || (tokenCount == bestTokenCount[i] && rankSum < bestRankSum[i])
                {
                    bestTokenCount[i] = tokenCount
                    bestRankSum[i] = rankSum
                    nextIndex[i] = end
                    nextTokenID[i] = candidate.tokenId
                }
            }
        }

        guard bestTokenCount[0] != Int.max else { return nil }

        var output: [Int] = []
        output.reserveCapacity(bestTokenCount[0])
        var cursor = 0
        while cursor < n {
            let tokenID = nextTokenID[cursor]
            let end = nextIndex[cursor]
            guard tokenID >= 0, end > cursor else { return nil }
            output.append(tokenID)
            cursor = end
        }

        return output
    }

    private func buildEncodingCandidatesByFirstByte() -> [UInt8: [EncodingCandidate]] {
        if let encodingCandidatesByFirstByte {
            return encodingCandidatesByFirstByte
        }

        var map: [UInt8: [EncodingCandidate]] = [:]
        map.reserveCapacity(256)

        for index in vocab.indices {
            let tokenId = nSpecial + index
            let bytes = tokenBytes(for: tokenId)
            guard !bytes.isEmpty, let first = bytes.first else { continue }
            let rank = vocab[index].rank ?? index
            let candidate = EncodingCandidate(tokenId: tokenId, rank: rank, bytes: bytes)
            map[first, default: []].append(candidate)
        }

        for key in map.keys {
            map[key]?.sort {
                if $0.bytes.count == $1.bytes.count {
                    return $0.rank < $1.rank
                }
                return $0.bytes.count > $1.bytes.count
            }
        }

        encodingCandidatesByFirstByte = map
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

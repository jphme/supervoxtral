import Foundation
import MLX

private final class ContentBiasTrieNode {
    var children: [Int: ContentBiasTrieNode] = [:]
    var isTerminal = false
}

public struct ContentBiasConfiguration: Sendable, Equatable {
    public var phrases: [String]
    public var strength: Float
    public var firstTokenFactor: Float

    public init(
        phrases: [String],
        strength: Float = 5.0,
        firstTokenFactor: Float = 0.2
    ) {
        self.phrases = phrases
        self.strength = strength
        self.firstTokenFactor = firstTokenFactor
    }
}

final class ContentBiasProcessor {
    private static let eosGuardDelta: Float = 5.0

    private let root = ContentBiasTrieNode()
    private let boost: Float
    private let firstTokenBoost: Float
    private let eosTokenId: Int

    private var activeNodes: [ContentBiasTrieNode] = []
    private var nextTokenIDs: Set<Int> = []
    private var firstTokenIDs: Set<Int> = []

    var hasBias: Bool { !root.children.isEmpty }

    init(configuration: ContentBiasConfiguration, tokenizer: VoxtralRealtimeTokenizer, eosTokenId: Int) {
        boost = configuration.strength
        firstTokenBoost = configuration.strength * configuration.firstTokenFactor
        self.eosTokenId = eosTokenId

        for phrase in configuration.phrases {
            let paths = allTokenizations(for: phrase, tokenizer: tokenizer)
            guard !paths.isEmpty else { continue }

            for path in paths {
                var node = root
                for tokenId in path {
                    if let child = node.children[tokenId] {
                        node = child
                    } else {
                        let newNode = ContentBiasTrieNode()
                        node.children[tokenId] = newNode
                        node = newNode
                    }
                }
                node.isTerminal = true
            }
        }

        firstTokenIDs = Set(root.children.keys)
    }

    func reset() {
        activeNodes.removeAll(keepingCapacity: true)
        nextTokenIDs.removeAll(keepingCapacity: true)
    }

    func update(tokenId: Int) {
        var updated: [ContentBiasTrieNode] = []
        updated.reserveCapacity(activeNodes.count + 1)

        for node in activeNodes {
            if let child = node.children[tokenId], !child.children.isEmpty {
                updated.append(child)
            }
        }

        if let rootChild = root.children[tokenId], !rootChild.children.isEmpty {
            updated.append(rootChild)
        }

        var deduped: [ContentBiasTrieNode] = []
        deduped.reserveCapacity(updated.count)
        var seen: Set<ObjectIdentifier> = []
        for node in updated {
            let id = ObjectIdentifier(node)
            if seen.insert(id).inserted {
                deduped.append(node)
            }
        }

        activeNodes = deduped
        recomputeNextTokenIDs()
    }

    func apply(logits: MLXArray) -> MLXArray {
        let logits1D = logits.ndim > 1 ? logits.squeezed() : logits
        let logitsValues = logits1D.asType(.float32).asArray(Float.self)
        guard let bias = biasDeltas(for: logitsValues) else {
            return logits
        }

        let biased = logits1D + MLXArray(bias)
        if logits.ndim > 1 {
            return biased.reshaped(logits.shape)
        }
        return biased
    }

    func biasDeltas(for logitsValues: [Float]) -> [Float]? {
        let hasContinuations = !nextTokenIDs.isEmpty
        let hasFirstTokenBias = firstTokenBoost > 0 && !hasContinuations && !firstTokenIDs.isEmpty
        if !hasContinuations && !hasFirstTokenBias {
            return nil
        }
        guard !logitsValues.isEmpty else { return nil }

        let maxLogit = logitsValues.max() ?? -Float.greatestFiniteMagnitude
        if eosTokenId >= 0 && eosTokenId < logitsValues.count {
            let eosLogit = logitsValues[eosTokenId]
            if eosLogit >= maxLogit - Self.eosGuardDelta {
                return nil
            }
        }

        var bias = [Float](repeating: 0, count: logitsValues.count)
        if hasContinuations {
            let target = maxLogit + boost
            for tokenId in nextTokenIDs where tokenId >= 0 && tokenId < logitsValues.count {
                let delta = target - logitsValues[tokenId]
                if delta > 0 {
                    bias[tokenId] = delta
                }
            }
        } else {
            for tokenId in firstTokenIDs where tokenId >= 0 && tokenId < logitsValues.count {
                bias[tokenId] = firstTokenBoost
            }
        }

        return bias.contains(where: { $0 != 0 }) ? bias : nil
    }
}

private extension ContentBiasProcessor {
    func recomputeNextTokenIDs() {
        var next: Set<Int> = []
        for node in activeNodes {
            next.formUnion(node.children.keys)
        }
        nextTokenIDs = next
    }

    func allTokenizations(for phrase: String, tokenizer: VoxtralRealtimeTokenizer) -> [[Int]] {
        let normalized = phrase
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return [] }

        var seen = Set<[Int]>()
        var paths: [[Int]] = []

        func addPath(_ path: [Int]?) {
            guard let path, !path.isEmpty else { return }
            if seen.insert(path).inserted {
                paths.append(path)
            }
        }

        let capitalized = normalized.first.map { String($0).uppercased() + normalized.dropFirst().lowercased() } ?? normalized
        let surfaceForms = Set([normalized, normalized.lowercased(), capitalized])
        for form in surfaceForms {
            addPath(tokenizer.encode(text: " " + form))
        }

        let chars = Array(normalized)
        if chars.count > 4 {
            for splitIndex in 3..<(chars.count - 1) {
                let firstPart = String(chars[0..<splitIndex])
                let restPart = String(chars[splitIndex...])
                guard let restTokens = tokenizer.encode(text: restPart), !restTokens.isEmpty else {
                    continue
                }

                let firstCapitalized = firstPart.first.map { String($0).uppercased() + firstPart.dropFirst().lowercased() } ?? firstPart
                let firstForms = Set([firstPart.lowercased(), firstCapitalized])
                for firstForm in firstForms {
                    guard let firstTokens = tokenizer.encode(text: " " + firstForm),
                          !firstTokens.isEmpty,
                          firstTokens.count <= 2
                    else {
                        continue
                    }
                    addPath(firstTokens + restTokens)
                }
            }
        }

        return paths
    }
}

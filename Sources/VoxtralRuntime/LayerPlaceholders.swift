import Foundation
import MLX
import MLXNN

/// Model construction uses placeholder tensors so loading does not spend time
/// initializing large random arrays that are immediately replaced by checkpoints.
enum VoxtralLayerPlaceholders {
    static func linear(withBias: Bool) -> Linear {
        let weight = MLXArray.zeros([1, 1], type: Float.self)
        let bias = withBias ? MLXArray.zeros([1], type: Float.self) : nil
        return Linear(weight: weight, bias: bias)
    }

    static func quantizedLinear(
        withBias: Bool,
        groupSize: Int = 64,
        bits: Int = 8,
        mode: QuantizationMode = .affine
    ) -> Linear {
        let weight = MLXArray.zeros([1, 1], type: UInt32.self)
        let bias = withBias ? MLXArray.zeros([1], type: Float.self) : nil
        let scales = MLXArray.zeros([1, 1], type: Float.self)
        let biases = MLXArray.zeros([1, 1], type: Float.self)

        return QuantizedLinear(
            weight: weight,
            bias: bias,
            scales: scales,
            biases: biases,
            groupSize: groupSize,
            bits: bits,
            mode: mode
        )
    }

    static func embedding(groupSize: Int = 64, bits: Int = 8) -> Embedding {
        let placeholderDim = max(groupSize, 64)
        return QuantizedEmbedding(
            weight: MLXArray.zeros([1, placeholderDim], type: Float.self),
            groupSize: groupSize,
            bits: bits,
            mode: .affine
        )
    }
}

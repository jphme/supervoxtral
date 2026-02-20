import Foundation
import MLX

public enum MelScale {
    case htk
    case slaney
}

public func melFilters(
    sampleRate: Int,
    nFft: Int,
    nMels: Int,
    fMin: Float = 0,
    fMax: Float? = nil,
    norm: String? = "slaney",
    melScale: MelScale = .htk
) -> MLXArray {
    let fMaxVal = fMax ?? Float(sampleRate) / 2.0
    let nFreqs = nFft / 2 + 1

    var allFreqs = [Float](repeating: 0, count: nFreqs)
    for i in 0..<nFreqs {
        allFreqs[i] = Float(i) * Float(sampleRate) / Float(nFft)
    }

    let hzToMel: (Float) -> Float
    let melToHz: (Float) -> Float

    switch melScale {
    case .htk:
        hzToMel = { freq in 2595.0 * log10(1.0 + freq / 700.0) }
        melToHz = { mel in 700.0 * (pow(10.0, mel / 2595.0) - 1.0) }
    case .slaney:
        let fSp: Float = 200.0 / 3.0
        let minLogHz: Float = 1000.0
        let minLogMel = (minLogHz - fMin) / fSp
        let logStep = log(Float(6.4)) / 27.0

        hzToMel = { freq in
            if freq < minLogHz {
                return (freq - fMin) / fSp
            }
            return minLogMel + log(freq / minLogHz) / logStep
        }
        melToHz = { mel in
            if mel < minLogMel {
                return fMin + fSp * mel
            }
            return minLogHz * exp(logStep * (mel - minLogMel))
        }
    }

    let mMin = hzToMel(fMin)
    let mMax = hzToMel(fMaxVal)

    var mPts = [Float](repeating: 0, count: nMels + 2)
    for i in 0..<(nMels + 2) {
        mPts[i] = mMin + Float(i) * (mMax - mMin) / Float(nMels + 1)
    }
    let fPts = mPts.map { melToHz($0) }

    var filterbank = [[Float]](repeating: [Float](repeating: 0, count: nMels), count: nFreqs)
    for i in 0..<nFreqs {
        for j in 0..<nMels {
            let low = fPts[j]
            let center = fPts[j + 1]
            let high = fPts[j + 2]

            if allFreqs[i] >= low && allFreqs[i] < center {
                filterbank[i][j] = (allFreqs[i] - low) / (center - low)
            } else if allFreqs[i] >= center && allFreqs[i] <= high {
                filterbank[i][j] = (high - allFreqs[i]) / (high - center)
            }
        }
    }

    if norm == "slaney" {
        for j in 0..<nMels {
            let enorm = 2.0 / (fPts[j + 2] - fPts[j])
            for i in 0..<nFreqs {
                filterbank[i][j] *= enorm
            }
        }
    }

    let flatFilters = filterbank.flatMap { $0 }
    return MLXArray(flatFilters).reshaped([nFreqs, nMels])
}

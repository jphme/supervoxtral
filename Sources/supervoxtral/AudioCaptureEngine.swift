import Foundation
import AVFoundation

final class AudioCaptureEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private var pendingSamples: [Float] = []
    private let maxBufferedSeconds: Double = 90.0

    let targetSampleRate: Double = 16000

    func start() throws {
        if engine != nil { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioCaptureEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create target format"])
        }

        let converter: AVAudioConverter?
        if nativeFormat.sampleRate != targetSampleRate || nativeFormat.channelCount != 1 {
            converter = AVAudioConverter(from: nativeFormat, to: targetFormat)
        } else {
            converter = nil
        }

        let nativeSampleRate = nativeFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let floats: [Float]
            if let converter {
                let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * self.targetSampleRate / nativeSampleRate)
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

                var error: NSError?
                var consumed = false
                converter.convert(to: converted, error: &error) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error != nil { return }

                floats = Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
            } else {
                floats = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            }

            self.lock.lock()
            self.samples.append(contentsOf: floats)
            self.pendingSamples.append(contentsOf: floats)
            let maxSamples = Int(self.targetSampleRate * self.maxBufferedSeconds)
            if self.samples.count > maxSamples {
                self.samples.removeFirst(self.samples.count - maxSamples)
            }
            if self.pendingSamples.count > maxSamples {
                self.pendingSamples.removeFirst(self.pendingSamples.count - maxSamples)
            }
            self.lock.unlock()
        }

        try engine.start()
        self.engine = engine
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: false)
        pendingSamples.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func snapshotLast(seconds: Double) -> [Float] {
        let maxSamples = Int(targetSampleRate * seconds)
        lock.lock()
        defer { lock.unlock() }

        guard !samples.isEmpty else { return [] }
        if samples.count <= maxSamples {
            return samples
        }
        return Array(samples.suffix(maxSamples))
    }

    func drainPending() -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        guard !pendingSamples.isEmpty else { return [] }
        let drained = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        return drained
    }
}

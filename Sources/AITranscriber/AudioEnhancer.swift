import Foundation

/// Memperjelas audio sebelum masuk ke Whisper: membuang dengung rendah dan menaikkan volume
/// rekaman yang pelan. Whisper (dan VAD-nya) bekerja jauh lebih baik pada sinyal yang cukup keras;
/// suara pelan sering dianggap "hening" lalu terlewat atau diganti teks karangan.
enum AudioEnhancer {
    /// Level suara bicara yang dituju (RMS, ~ -20 dBFS).
    private static let targetRMS: Float = 0.1
    private static let maxGain: Float = 30
    private static let frameSize = 1600 // 0,1 detik pada 16 kHz

    static func enhance(_ input: [Float]) -> [Float] {
        guard input.count > frameSize else { return input }
        var samples = highPass(input, cutoff: 80, sampleRate: 16_000)

        // Level suara bicara = persentil ke-90 dari RMS per frame, jadi jeda hening
        // dan derau latar tidak ikut menurunkan perkiraan.
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frameSize)
        var i = 0
        while i + frameSize <= samples.count {
            var sum: Float = 0
            for j in i..<i + frameSize { sum += samples[j] * samples[j] }
            levels.append((sum / Float(frameSize)).squareRoot())
            i += frameSize
        }
        levels.sort()
        let speechLevel = levels[min(levels.count - 1, Int(Float(levels.count) * 0.9))]
        guard speechLevel > 1e-4 else { return samples }

        let gain = min(maxGain, max(1, targetRMS / speechLevel))
        guard gain > 1.05 else { return samples }

        // Penguatan lalu pembatas halus agar puncak suara tidak pecah.
        for k in samples.indices {
            let v = samples[k] * gain
            samples[k] = abs(v) <= 0.8 ? v : (v < 0 ? -1 : 1) * (0.8 + 0.2 * tanh((abs(v) - 0.8) / 0.2))
        }
        return samples
    }

    /// Filter high-pass satu kutub: membuang DC offset dan dengung/guncangan di bawah `cutoff` Hz.
    private static func highPass(_ x: [Float], cutoff: Float, sampleRate: Float) -> [Float] {
        let rc = 1 / (2 * Float.pi * cutoff)
        let dt = 1 / sampleRate
        let a = rc / (rc + dt)
        var y = [Float](repeating: 0, count: x.count)
        var prevX = x[0], prevY: Float = 0
        for n in 1..<x.count {
            prevY = a * (prevY + x[n] - prevX)
            prevX = x[n]
            y[n] = prevY
        }
        return y
    }
}

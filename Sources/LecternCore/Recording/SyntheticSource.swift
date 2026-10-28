import AVFoundation
import Foundation

/// A microphone stand-in for tests. By default it plays a 1 kHz beep in the first 0.1 s of every
/// second, so beeps on whole seconds in the file prove the timeline equals wall-clock time; with an
/// input file it plays that file instead. Time is simulated unless `realTime` is set.
struct SyntheticSource {
    var duration: Double
    /// (start, length) stretches where no buffers arrive while time passes (sleep, lid closed).
    var gaps: [(Double, Double)] = []
    /// (start, length) stretches where the writer refuses audio.
    var stalls: [(Double, Double)] = []
    var realTime = false
    var inputFile: AVAudioFile?

    func run(_ pipeline: AudioPipeline) {
        let n = 512
        let format = inputFile?.processingFormat
            ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let sr = format.sampleRate
        let origin = 1000.0
        var simulated = origin
        pipeline.now = { simulated }
        let stalls = self.stalls
        pipeline.stalled = { t in stalls.contains { t - origin >= $0.0 && t - origin < $0.0 + $0.1 } }
        pipeline.deviceName = "synthetic"
        let gaps = self.gaps, duration = self.duration, realTime = self.realTime, file = inputFile

        func buffer(at t: Double) -> AVAudioPCMBuffer {
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            if let file {
                for c in 0..<Int(format.channelCount) { memset(pcm.floatChannelData![c], 0, n * 4) }
                let frame = AVAudioFramePosition(t * sr)
                if frame < file.length {
                    file.framePosition = frame
                    try? file.read(into: pcm, frameCount: AVAudioFrameCount(n))
                }
                pcm.frameLength = AVAudioFrameCount(n)
                return pcm
            }
            pcm.frameLength = AVAudioFrameCount(n)
            let v = pcm.floatChannelData![0]
            for i in 0..<n {
                let ti = t + Double(i) / sr
                v[i] = ti - floor(ti) < 0.1 ? Float(0.5 * sin(2 * Double.pi * 1000 * ti)) : 0
            }
            return pcm
        }

        Thread.detachNewThread {
            var t = 0.0
            var lastEnd: Double?
            let wall0 = monotonicNow()
            while t < duration {
                if let g = gaps.first(where: { t >= $0.0 && t < $0.0 + $0.1 }) {
                    t = g.0 + g.1
                    continue
                }
                let start = t
                let skipped = lastEnd.map { start - $0 } ?? 0
                t += Double(n) / sr
                lastEnd = t
                if realTime {
                    let wait = wall0 + t - monotonicNow()
                    if wait > 0 { usleep(useconds_t(wait * 1e6)) }
                }
                let done = autoreleasepool { () -> Bool in
                    let pcm = buffer(at: start)
                    pipeline.queue.sync {
                        simulated = origin + t
                        pipeline.append(pcm, start: origin + start, discontinuity: skipped)
                    }
                    // real writer back-pressure: the producer waits (not during a simulated stall)
                    while pipeline.queue.sync(execute: {
                        pipeline.queuedAudio > min(pipeline.queueLimit / 2, Int(pipeline.rate / 2))
                            && !pipeline.stalled(simulated) && pipeline.error == nil
                    }) {
                        usleep(500)
                        pipeline.queue.sync { pipeline.pump() }
                    }
                    return pipeline.queue.sync { pipeline.closing }
                }
                if done { return }
            }
            pipeline.queue.sync { simulated = origin + max(t, duration) }
            pipeline.queue.async { pipeline.close() }
        }
    }
}

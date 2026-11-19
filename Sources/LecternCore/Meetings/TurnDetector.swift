import Foundation

/// Finds where the other side of a call stops talking. It is fed the track as it arrives and tells
/// when a turn has ended: enough speech, then a pause. No model, only loudness against the room. The
/// room is the quietest the line has been in the last few seconds (speech always has gaps between
/// words, a hum or a fan has none), so a noisy line does not look like endless speech.
public struct TurnDetector: Sendable {
    public struct Timing: Sendable {
        /// A turn has at least this much speech in it ("Why?" has); a click has not.
        public var minSpeech: Double = 0.4
        /// This much quiet after speech ends the turn.
        public var pause: Double = 0.9
        /// A speaker who never pauses is cut here: the helper should not wait for minutes.
        public var maxTurn: Double = 30
        /// Sound kept before the first loud frame, so the first syllable is not cut off.
        public var lead: Double = 0.3

        public init() {}
    }

    public struct Turn: Equatable, Sendable {
        /// Frames since the start of the track.
        public var start: Int
        public var end: Int
    }

    public var timing = Timing()
    public let sampleRate: Double
    /// 20 ms of sound is judged at a time.
    let frame: Int
    private var position = 0
    private var rest: [Int16] = []
    /// Mean square of the last five seconds of frames; the lowest of them is the room.
    private var recent: [Double] = []
    private var cursor = 0
    static let window = 250
    private var speechStart: Int?
    private var speechFrames = 0
    private var quietFrames = 0

    public init(sampleRate: Double, timing: Timing = Timing()) {
        self.sampleRate = sampleRate
        self.timing = timing
        frame = max(1, Int(sampleRate / 50))
    }

    /// True while someone is in the middle of a turn.
    public var isSpeaking: Bool { speechStart != nil }

    /// Tells the detector that the track jumped (the ring was read late): the turn in progress is dropped.
    public mutating func reset(to frame: Int) {
        position = frame
        rest = []
        recent = []
        cursor = 0
        speechStart = nil
        speechFrames = 0
        quietFrames = 0
    }

    /// Nothing has arrived for `seconds`: when nothing plays, the system sends no sound at all, and the
    /// silence only reaches the track a couple of seconds later. Waiting for it would make every answer
    /// that much later, so the quiet is counted from the clock. Returns the turn this ends, if any.
    public mutating func quiet(for seconds: Double) -> Turn? {
        guard let start = speechStart, Double(quietFrames) / sampleRate + seconds >= timing.pause else { return nil }
        let enough = Double(speechFrames) / sampleRate >= timing.minSpeech
        let turn = Turn(start: start, end: position - quietFrames)
        speechStart = nil
        speechFrames = 0
        quietFrames = 0
        return enough ? turn : nil
    }

    /// Feeds the next samples of the track. Returns the turns that ended in them.
    public mutating func feed(_ samples: [Int16]) -> [Turn] {
        var turns: [Turn] = []
        rest.append(contentsOf: samples)
        var offset = 0
        while rest.count - offset >= frame {
            var sum = 0.0
            for i in offset..<(offset + frame) {
                let v = Double(rest[i]) / 32768
                sum += v * v
            }
            let level = sum / Double(frame)
            if recent.count < Self.window {
                recent.append(level)
            } else {
                recent[cursor] = level
                cursor = (cursor + 1) % Self.window
            }
            let floor = recent.min() ?? 0
            // louder than the room by a clear margin (about 10 dB), and louder than any quiet room
            let loud = level > max(floor * 10, 2e-6)
            if loud {
                if speechStart == nil { speechStart = max(0, position - Int(timing.lead * sampleRate)) }
                speechFrames += frame
                quietFrames = 0
            } else if speechStart != nil {
                quietFrames += frame
            }
            position += frame
            offset += frame
            if let start = speechStart {
                let quiet = Double(quietFrames) / sampleRate
                let length = Double(position - start) / sampleRate
                if quiet >= timing.pause || length >= timing.maxTurn {
                    if Double(speechFrames) / sampleRate >= timing.minSpeech {
                        turns.append(Turn(start: start, end: position - max(0, quietFrames - frame * 10)))
                    }
                    speechStart = nil
                    speechFrames = 0
                    quietFrames = 0
                }
            }
        }
        rest.removeFirst(offset)
        return turns
    }
}

import AVFoundation

/// How long a sound file is, from its header.
public enum AudioLength {
    public static func seconds(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

extension Library {
    /// Fills in the length of finished recordings that have none (lectures imported without it), and
    /// saves the sessions that changed. Returns how many were changed.
    @discardableResult
    public func completeDurations(_ sessions: [Session]) -> Int {
        var changed = 0
        for var session in sessions {
            var touched = false
            for index in session.recordings.indices where session.recordings[index].duration == nil && !session.recordings[index].inProgress {
                let url = folder(of: session).appendingPathComponent(session.recordings[index].file)
                if let length = AudioLength.seconds(of: url) {
                    session.recordings[index].duration = length
                    touched = true
                }
            }
            if touched, (try? save(session)) != nil { changed += 1 }
        }
        return changed
    }
}

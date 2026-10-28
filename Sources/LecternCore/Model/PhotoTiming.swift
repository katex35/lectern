import Foundation
import ImageIO

/// Puts photos of the board on a session's timeline by the moment they were taken.
public enum PhotoTiming {
    /// When the photo was taken: the camera's own time, else the file's creation date.
    public static func takenDate(of url: URL) -> Date? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            if let date = exifDate(text, offset: offset) { return date }
        }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
    }

    /// "2026:10:27 10:42:13" with an optional "+03:00"; without one the photo is taken to be from this Mac's time zone.
    static func exifDate(_ text: String, offset: String?, timeZone: TimeZone = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = timeZone
        if let offset, let zone = zone(offset) { formatter.timeZone = zone }
        return formatter.date(from: text)
    }

    private static func zone(_ offset: String) -> TimeZone? {
        let sign: Int = offset.hasPrefix("-") ? -1 : 1
        let parts = offset.drop(while: { $0 == "+" || $0 == "-" }).split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return TimeZone(secondsFromGMT: sign * (parts[0] * 3600 + parts[1] * 60))
    }

    /// The recording that was running at `date` and the seconds into it. A photo taken up to `margin`
    /// before or after the recordings (or in a break) goes to the nearest end.
    public static func place(_ date: Date, in session: Session, now: Date = Date(),
                             margin: TimeInterval = 15 * 60) -> (recording: String, time: Double)? {
        nearest(date, in: session, now: now, margin: margin).map { ($0.recording, $0.time) }
    }

    /// The spot in `session` closest to `date`, with how far outside its recordings that is.
    static func nearest(_ date: Date, in session: Session, now: Date,
                        margin: TimeInterval) -> (recording: String, time: Double, distance: TimeInterval)? {
        var best: (recording: String, time: Double, distance: TimeInterval)?
        for recording in session.orderedRecordings {
            let length = recording.duration ?? (recording.inProgress ? max(0, now.timeIntervalSince(recording.start)) : 0)
            let into = date.timeIntervalSince(recording.start)
            let time = min(max(0, into), length)
            let distance = into < 0 ? -into : max(0, into - length)
            if distance <= margin, distance < (best?.distance ?? .infinity) {
                best = (recording.file, time, distance)
            }
        }
        return best
    }

    /// The session that was being recorded when the photo was taken: of two lectures back to back, the
    /// one whose recording is closest.
    public static func session(for date: Date, among sessions: [Session], now: Date = Date(),
                               margin: TimeInterval = 15 * 60) -> Session? {
        sessions.compactMap { session in nearest(date, in: session, now: now, margin: margin).map { (session, $0.distance) } }
            .min { $0.1 < $1.1 }?.0
    }
}

extension Library {
    /// Copies photos into the session's `board` folder and places each on its timeline. A name already
    /// taken gets a number, so two IMG_0001.jpg from different folders are both kept. A photo that cannot
    /// be copied is skipped; the error comes back only when none could be.
    @discardableResult
    public func addPhotos(_ urls: [URL], to session: Session, now: Date = Date()) throws -> Session {
        var session = reload(session) ?? session
        let board = folder(of: session).appendingPathComponent("board", isDirectory: true)
        try FileManager.default.createDirectory(at: board, withIntermediateDirectories: true)
        var failure: Error?
        var added = 0
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
            var target = board.appendingPathComponent(url.lastPathComponent)
            var number = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = board.appendingPathComponent("\(name)-\(number)\(suffix)")
                number += 1
            }
            do {
                try FileManager.default.copyItem(at: url, to: target)
            } catch {
                failure = error
                continue
            }
            let taken = PhotoTiming.takenDate(of: url)
            let spot = taken.flatMap { PhotoTiming.place($0, in: session, now: now) }
            session.photos.append(BoardPhoto(file: target.lastPathComponent, taken: taken, recording: spot?.recording, time: spot?.time))
            added += 1
        }
        if added == 0, let failure { throw failure }
        try save(session)
        return session
    }
}

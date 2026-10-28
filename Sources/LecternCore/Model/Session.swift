import Foundation

public enum SessionKind: String, Codable, Sendable {
    case lecture
    case meeting
}

/// A stretch of a recording where no microphone audio exists. The file still contains silence
/// there, so the recording's timeline stays equal to wall-clock time.
public struct RecordingGap: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// The microphone delivered nothing: system sleep, lid closed, device removed.
        case noInput
        /// The device skipped a short stretch (a dropped buffer).
        case droppedBuffer
        /// The file writer fell so far behind that queued audio was discarded.
        case writerStalled
    }

    /// Seconds from the start of the recording.
    public var start: Double
    public var duration: Double
    public var reason: Reason

    public init(start: Double, duration: Double, reason: Reason) {
        self.start = start
        self.duration = duration
        self.reason = reason
    }
}

public struct DeviceChange: Codable, Hashable, Sendable {
    public var time: Double
    public var device: String

    public init(time: Double, device: String) {
        self.time = time
        self.device = device
    }
}

/// One audio file of a session. A lecture with a break has two.
public struct RecordingInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String { file }
    /// File name inside the session folder.
    public var file: String
    /// Wall-clock time of the first sample.
    public var start: Date
    public var duration: Double?
    public var device: String?
    public var gaps: [RecordingGap]
    public var deviceChanges: [DeviceChange]
    /// Set when the recording did not finish cleanly (crash, disk error).
    public var problem: String?
    /// True while the recorder is still writing it.
    public var inProgress: Bool
    /// Process id of the recorder helper while `inProgress`, to reattach after the app restarts.
    public var recorderPID: Int32?

    public init(file: String, start: Date, duration: Double? = nil, device: String? = nil,
                gaps: [RecordingGap] = [], deviceChanges: [DeviceChange] = [], problem: String? = nil,
                inProgress: Bool = false) {
        self.file = file
        self.start = start
        self.duration = duration
        self.device = device
        self.gaps = gaps
        self.deviceChanges = deviceChanges
        self.problem = problem
        self.inProgress = inProgress
    }

    public var silentSeconds: Double { gaps.reduce(0) { $0 + $1.duration } }
}

/// A note typed during or after the lecture, anchored to a moment of a recording.
public struct Marker: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var recording: String
    /// Seconds into that recording.
    public var time: Double
    public var text: String
    public var created: Date

    public init(id: UUID = UUID(), recording: String, time: Double, text: String, created: Date = Date()) {
        self.id = id
        self.recording = recording
        self.time = time
        self.text = text
        self.created = created
    }
}

/// A photo of the board or slides, placed on the timeline by its capture time when known.
public struct BoardPhoto: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// File name inside the session's `board` folder.
    public var file: String
    public var taken: Date?
    public var recording: String?
    public var time: Double?

    public init(id: UUID = UUID(), file: String, taken: Date? = nil, recording: String? = nil, time: Double? = nil) {
        self.id = id
        self.file = file
        self.taken = taken
        self.recording = recording
        self.time = time
    }
}

public struct Session: Codable, Hashable, Identifiable, Sendable {
    /// Folder name, unique within its course (or within meetings).
    public var id: String
    public var kind: SessionKind
    public var courseID: String?
    public var title: String
    public var date: Date
    public var week: Int?
    public var recordings: [RecordingInfo]
    public var markers: [Marker]
    public var photos: [BoardPhoto]

    public init(id: String, kind: SessionKind, courseID: String?, title: String, date: Date, week: Int? = nil,
                recordings: [RecordingInfo] = [], markers: [Marker] = [], photos: [BoardPhoto] = []) {
        self.id = id
        self.kind = kind
        self.courseID = courseID
        self.title = title
        self.date = date
        self.week = week
        self.recordings = recordings
        self.markers = markers
        self.photos = photos
    }

    /// Recordings in time order; the session timeline plays them back to back.
    public var orderedRecordings: [RecordingInfo] { recordings.sorted { $0.start < $1.start } }

    public var totalDuration: Double { recordings.reduce(0) { $0 + ($1.duration ?? 0) } }

    public var isRecording: Bool { recordings.contains { $0.inProgress } }
}

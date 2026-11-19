import Foundation

/// A meeting found in the front tab of a browser.
public struct MeetingTab: Hashable, Sendable {
    /// The service as the user knows it ("Meet").
    public var service: String
    /// Bundle id of the browser showing it.
    public var browser: String

    public init(service: String, browser: String) {
        self.service = service
        self.browser = browser
    }
}

/// What an automatic recording needs remembered while it runs, also across a restart of the app.
public struct AutomaticRecording: Codable, Hashable, Sendable {
    /// `MeetingApp.id` of the app whose microphone started it.
    public var app: String
    /// Browsers whose front tab keeps the recording going while the microphone is released.
    public var keepAlive: [String]
    /// False while "Is this a meeting?" has no answer: such a recording is not processed on its own.
    public var confirmed: Bool

    public init(app: String, keepAlive: [String] = [], confirmed: Bool = true) {
        self.app = app
        self.keepAlive = keepAlive
        self.confirmed = confirmed
    }
}

/// Decides when a meeting recording starts and ends by itself. It only sees who uses the microphone
/// and the speakers, once a second, and answers with what to do; it touches no audio, no clock and no
/// screen, which is what lets every rule here be tested against a scripted timeline.
///
/// - A meeting app holding the microphone for `startAfter` starts a recording.
/// - The recording ends `stopAfter` after the last sign of the call: a meeting app on the microphone,
///   an app like Zoom still playing sound, or the meeting tab still in front of a browser that plays.
/// - After the user stops a recording themselves, or says "not a meeting", the same call is not
///   picked up again: the policy waits until it has been quiet for `rearmAfter`.
public struct AutoRecordPolicy: Sendable {
    public struct Timing: Sendable {
        /// A meeting app must hold the microphone this long before recording starts.
        public var startAfter: TimeInterval = 4
        /// The recording ends this long after the last sign of the call.
        public var stopAfter: TimeInterval = 180
        /// How long things must stay quiet before a stopped or rejected call may start a recording again.
        public var rearmAfter: TimeInterval = 30
        /// A meeting tab keeps a recording going without the microphone for at most this long.
        public var keepAliveLimit: TimeInterval = 3600
        /// Tabs are read at most this often while a recording goes on.
        public var tabCheckEvery: TimeInterval = 15
        /// A tab reading that has not come back by then is given up.
        public var tabTimeout: TimeInterval = 20
        /// The end is asked for again this often until the recording is reported over.
        public var stopRetry: TimeInterval = 10
        /// A call whose app held the microphone for less than this in all is too short to be sure of.
        public var briefCall: TimeInterval = 60

        public init() {}
    }

    public struct Start: Equatable, Sendable {
        public var app: MeetingApp
        /// The meeting recognised in a browser tab, nil for an app of its own or an unknown page.
        public var service: String?
        public var recording: AutomaticRecording
        /// Not known to be a meeting: record and ask.
        public var ask: Bool
    }

    public enum Effect: Equatable, Sendable {
        /// Read the front tabs of these browsers and answer with `tabsRead(token:found:now:)`.
        case readTabs(browsers: [String], token: Int)
        case start(Start)
        case stop
    }

    public enum End: Sendable {
        /// The policy asked for it, or the recorder ended on its own.
        case finished
        /// The user pressed Stop.
        case stoppedByUser
        /// The user said it was not a meeting.
        case rejected
        /// The recording never started.
        case failed
    }

    struct PendingStart: Sendable {
        var token: Int
        var since: Date
        var app: String
        var asked: Date
    }

    struct Current: Sendable {
        var recording: AutomaticRecording
        var lastMeeting: Date
        var lastMic: Date
        var lastTabCheck = Date.distantPast
        /// Seconds a meeting app was seen on the microphone during this recording.
        var micSeconds = 0
        var pendingCheck: (token: Int, asked: Date)?
        /// When the end was last asked for. Asked again now and then: the recorder may have been busy.
        var stopAsked: Date?
    }

    public var timing = Timing()
    public private(set) var enabled = false
    /// The recording the policy started, or took over after a restart.
    public var current: AutomaticRecording? { running?.recording }
    /// A call is going on that must not start a recording (the user ended or refused one for it).
    public private(set) var suppressed = false

    var running: Current?
    var pendingStart: PendingStart?
    var seenSince: Date?
    var seenApp: MeetingApp?
    var lastSeen: Date?
    var rejectedApp: String?
    var rejectedSeen = Date.distantPast
    var wasBusy = false
    var token = 0
    /// Nothing was observed yet since the policy was made or turned on.
    var needsBaseline = true

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// Turning it on in the middle of a call does not jump onto that call.
    public mutating func setEnabled(_ on: Bool, now: Date) {
        guard on != enabled else { return }
        enabled = on
        pendingStart = nil
        if on { needsBaseline = true }
        if on, let lastSeen, now.timeIntervalSince(lastSeen) < timing.rearmAfter { suppressed = true }
    }

    /// True when the call being recorded had its app on the microphone only briefly so far: a voice
    /// message or a microphone opened by mistake looks like that. Such a recording is kept, but not
    /// processed on its own.
    public var isBrief: Bool {
        guard let running else { return false }
        return Double(running.micSeconds) < timing.briefCall
    }

    /// The app found a recording still running after a restart and governs it again.
    public mutating func adopt(_ recording: AutomaticRecording, now: Date) {
        running = Current(recording: recording, lastMeeting: now, lastMic: now)
    }

    /// The answer to "Is this a meeting?" was yes.
    public mutating func confirm() {
        running?.recording.confirmed = true
    }

    /// The recording the policy started is over.
    public mutating func ended(_ how: End, now: Date) {
        guard let was = running else { return }
        running = nil
        switch how {
        case .finished:
            break
        case .stoppedByUser, .failed:
            // a start that failed (no permission, no microphone) is not tried again every second
            suppressed = true
        case .rejected:
            rejectedApp = was.recording.app
            rejectedSeen = now
        }
    }

    /// Once a second. `recorderBusy`: the recorder is in use for something this policy did not start
    /// (a lecture, a meeting started by hand, a break).
    public mutating func observe(_ users: [AudioUser], recorderBusy: Bool, now: Date) -> [Effect] {
        let micApps = users.filter(\.input).compactMap(MeetingApps.app(for:))
        if let rejected = rejectedApp {
            if micApps.contains(where: { $0.id == rejected }) {
                rejectedSeen = now
            } else if now.timeIntervalSince(rejectedSeen) >= timing.rearmAfter {
                rejectedApp = nil
            }
        }
        // an app of its own (Zoom) comes before a browser or a voice message
        let candidates = micApps.filter { $0.id != rejectedApp }
        let starter = candidates.first { !$0.ask } ?? candidates.first
        let inCall = starter != nil || users.contains { $0.output && MeetingApps.app(for: $0)?.outputMeansCall == true }
        if let starter {
            // another app taking over counts its own four seconds
            if seenSince == nil || seenApp?.id != starter.id { seenSince = now }
            seenApp = starter
        } else {
            seenSince = nil
            seenApp = nil
        }
        if inCall { lastSeen = now }
        // The first look after starting up or being turned on: a call already going on then is not
        // joined in the middle. The user can still record it by hand.
        if needsBaseline {
            needsBaseline = false
            if inCall, running == nil { suppressed = true }
        }
        // a recording made by hand has just ended: the call it belonged to is not picked up again
        if wasBusy, !recorderBusy, running == nil { suppressed = true }
        wasBusy = recorderBusy
        if suppressed, now.timeIntervalSince(lastSeen ?? .distantPast) >= timing.rearmAfter { suppressed = false }
        if let pending = pendingStart, now.timeIntervalSince(pending.asked) >= timing.tabTimeout { pendingStart = nil }

        guard var current = running else {
            guard enabled, !suppressed, !recorderBusy, pendingStart == nil, let starter, let since = seenSince,
                  now.timeIntervalSince(since) >= timing.startAfter else { return [] }
            if starter.browsers.isEmpty {
                return [begin(starter, service: nil, keepAlive: [], ask: starter.ask, now: now)]
            }
            token += 1
            pendingStart = PendingStart(token: token, since: since, app: starter.id, asked: now)
            return [.readTabs(browsers: starter.browsers, token: token)]
        }

        var effects: [Effect] = []
        if starter != nil {
            current.lastMic = now
            current.micSeconds += 1
        }
        if let check = current.pendingCheck, now.timeIntervalSince(check.asked) >= timing.tabTimeout { current.pendingCheck = nil }
        if inCall {
            current.lastMeeting = now
        } else if !current.recording.keepAlive.isEmpty, current.pendingCheck == nil,
                  now.timeIntervalSince(current.lastMic) < timing.keepAliveLimit,
                  now.timeIntervalSince(current.lastTabCheck) >= timing.tabCheckEvery,
                  users.contains(where: { $0.output && MeetingApps.app(for: $0)?.id == current.recording.app }) {
            // the microphone was released but the browser still plays: a muted meeting, if its tab is in front
            token += 1
            current.pendingCheck = (token, now)
            current.lastTabCheck = now
            effects.append(.readTabs(browsers: current.recording.keepAlive, token: token))
        }
        // never ended while tabs are being read: the answer may keep it going
        if current.pendingCheck == nil, now.timeIntervalSince(current.lastMeeting) >= timing.stopAfter,
           now.timeIntervalSince(current.stopAsked ?? .distantPast) >= timing.stopRetry {
            current.stopAsked = now
            effects.append(.stop)
        }
        running = current
        return effects
    }

    /// The front tabs asked for with `readTabs` were read. `found`: the first one that is a meeting.
    public mutating func tabsRead(token: Int, found: MeetingTab?, recorderBusy: Bool, now: Date) -> [Effect] {
        if let pending = pendingStart, pending.token == token {
            pendingStart = nil
            // the microphone was released, another app took over or a recording began meanwhile: the
            // next session counts its own four seconds
            guard running == nil, enabled, !suppressed, !recorderBusy, seenSince == pending.since,
                  let app = seenApp, app.id == pending.app else { return [] }
            if let found {
                return [begin(app, service: found.service, keepAlive: [found.browser], ask: false, now: now)]
            }
            return [begin(app, service: nil, keepAlive: [], ask: app.ask, now: now)]
        }
        if running?.pendingCheck?.token == token {
            running?.pendingCheck = nil
            if found != nil { running?.lastMeeting = now }
        }
        return []
    }

    private mutating func begin(_ app: MeetingApp, service: String?, keepAlive: [String], ask: Bool, now: Date) -> Effect {
        let recording = AutomaticRecording(app: app.id, keepAlive: keepAlive, confirmed: !ask)
        running = Current(recording: recording, lastMeeting: now, lastMic: now)
        return .start(Start(app: app, service: service, recording: recording, ask: ask))
    }
}

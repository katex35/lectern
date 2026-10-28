import AppKit
import Foundation
import LecternCore
import Observation
import SwiftUI

enum Screen: Hashable {
    case home
    case recording
    case session(SessionRef)
}

/// A session is unique by its folder inside a course (or inside meetings).
struct SessionRef: Hashable {
    var courseID: String?
    var id: String

    init(_ session: Session) {
        courseID = session.courseID
        id = session.id
    }
}

@MainActor @Observable
final class AppModel {
    let library: Library
    let schedule = Schedule()
    let recorder = RecordingController()
    let processing = ProcessingCenter()
    let chat = ChatCenter()
    private(set) var courses: [Course] = []
    /// Every lecture and meeting, newest first.
    private(set) var sessions: [Session] = []
    var screen: Screen = .home
    var sidebarVisible = true
    /// The course in the add or edit sheet.
    var editingCourse: CourseDraft?
    /// The search panel is open.
    var searching = false
    /// What was last searched for; kept when the panel closes.
    var searchQuery = ""

    /// Where a search result leads: the tab of the lecture and, in a transcript, the moment to play.
    struct Jump: Equatable {
        var session: SessionRef
        var source: SearchHit.Source
        var time: TimeInterval?
    }

    /// Taken by the lecture page once it is open.
    var jump: Jump?
    /// The service that writes notes, read from the keychain at launch and after Settings change it.
    private(set) var noteModelName = ""

    init(library: Library) {
        self.library = library
        recorder.model = self
        processing.model = self
        chat.model = self
        reload()
        // an empty library can start from the folders of the original ders-kayit tool (copied, never moved)
        if courses.isEmpty, let source = ProcessInfo.processInfo.environment["LECTERN_IMPORT"], !source.isEmpty {
            let url = URL(fileURLWithPath: (source as NSString).expandingTildeInPath, isDirectory: true)
            if DersKayitImporter.canImport(url) {
                _ = try? DersKayitImporter(source: url, library: library).run()
                reload()
            }
        }
        refreshAccounts()
        Reminders.shared.start(self)
    }

    func refreshAccounts() {
        Providers.accountsChanged()
        noteModelName = ProviderSummary.noteModel()
    }

    /// The library given in `LECTERN_LIBRARY`, or ~/Documents/Lectern.
    static func defaultLibrary() -> Library {
        if let path = ProcessInfo.processInfo.environment["LECTERN_LIBRARY"], !path.isEmpty {
            return Library(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
        }
        return Library(root: Library.defaultRoot)
    }

    /// Goes up on every reload. Notes and transcripts are read from files, and a list of sessions that
    /// comes back equal tells no view to redraw; views that read files watch this instead.
    private(set) var revision = 0

    func reload() {
        courses = library.courses()
        sessions = (courses.flatMap { library.sessions(ofCourse: $0.id) } + library.meetings())
            .sorted { $0.date > $1.date }
        revision += 1
    }

    func course(_ id: String?) -> Course? {
        courses.first { $0.id == id }
    }

    func session(_ ref: SessionRef) -> Session? {
        sessions.first { $0.id == ref.id && $0.courseID == ref.courseID }
    }

    func folder(of session: Session) -> URL {
        library.folder(of: session)
    }

    var nextLecture: (course: Course, start: Date)? {
        schedule.next(after: Date(), courses: courses).map { ($0.match.course, $0.start) }
    }

    /// The course whose slot is on now (with lead and trail time).
    var currentLecture: Course? {
        schedule.current(at: Date(), courses: courses)?.course
    }

    func open(_ session: Session) {
        withAnimation(Theme.ease) { screen = .session(SessionRef(session)) }
    }

    func addCourse() {
        editingCourse = CourseDraft()
    }

    func edit(_ course: Course) {
        editingCourse = CourseDraft(course)
    }

    func goHome() {
        withAnimation(Theme.ease) { screen = recorder.isActive ? .recording : .home }
    }

    /// Records the lecture on now, the given course, or a meeting when `course` is nil and none is on.
    func record(_ course: Course?, meeting: Bool = false) {
        withAnimation(Theme.ease) { screen = .recording }
        let target = meeting ? nil : (course ?? currentLecture)
        Task { await recorder.start(course: target) }
    }

    /// Text in the session folder (`notes.md`, `transcript.txt`, ...), nil when missing.
    func text(_ file: String, in session: Session) -> String? {
        _ = revision
        return try? String(contentsOf: folder(of: session).appendingPathComponent(file), encoding: .utf8)
    }

    // MARK: photos

    /// A short message in the top bar; it goes away after a few seconds.
    private(set) var notice: String?

    func show(_ text: String) {
        withAnimation(Theme.quick) { notice = text }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if notice == text { withAnimation(Theme.quick) { notice = nil } }
        }
    }

    /// Adds board photos to a session; notes already written are written again with the photos in place.
    func addPhotos(_ urls: [URL], to session: Session) {
        let photos = urls.filter(BoardPhotos.isPhoto)
        guard !photos.isEmpty else { return }
        do {
            let updated = try library.addPhotos(photos, to: session)
            reload()
            show(L("photos.added", photos.count))
            // during the lecture the notes come at the end anyway
            if !updated.isRecording, text("notes.md", in: updated) != nil { processing.process(updated) }
        } catch {
            show(error.localizedDescription)
        }
    }

    /// Photos dropped on the window: each goes to the lecture that was being recorded when it was taken.
    /// The rest go to the lecture on screen, if there is one.
    func importPhotos(_ urls: [URL]) {
        var groups: [SessionRef: (session: Session, urls: [URL])] = [:]
        var unmatched: [URL] = []
        for url in urls where BoardPhotos.isPhoto(url) {
            if let date = PhotoTiming.takenDate(of: url), let session = PhotoTiming.session(for: date, among: sessions) {
                groups[SessionRef(session), default: (session, [])].urls.append(url)
            } else {
                unmatched.append(url)
            }
        }
        if case .session(let ref) = screen, let current = session(ref), !unmatched.isEmpty {
            groups[ref, default: (current, [])].urls += unmatched
            unmatched = []
        }
        for group in groups.values { addPhotos(group.urls, to: group.session) }
        if !unmatched.isEmpty {
            show(L("photos.unmatched", unmatched.count))
        } else if let first = groups.values.first?.session, screen != .session(SessionRef(first)) {
            open(first)
        }
    }
}

@MainActor @Observable
final class RecordingController {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        /// Closing the first half before a break.
        case pausing
        /// Between the two halves of a lecture; the next recording joins the same session.
        case onBreak
        case stopping
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    private(set) var breakStartedAt: Date?
    private(set) var session: Session?
    private(set) var course: Course?
    private(set) var file: String?
    /// Recent loudness, 0...1, oldest first.
    private(set) var levels: [CGFloat] = Array(repeating: 0, count: 56)
    private(set) var notes: [Marker] = []
    /// Advances once a second while active; the menu bar label reads it, since a TimelineView there
    /// keeps the status item redrawing without pause.
    private(set) var tick = Date()
    weak var model: AppModel?
    private var client: RecorderClient?
    private var ticker: Timer?
    /// Stop was pressed while the first half was still closing for a break.
    private var stopAfterPause = false
    /// The session a break belongs to; kept when resuming fails so a retry still joins it.
    private var breakSession: Session?
    /// A helper that ended before `start` had taken it over, with its report.
    private var endedEarly: (client: ObjectIdentifier, report: RecordingReport)?

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick = Date() }
        }
    }

    var isActive: Bool {
        switch phase {
        case .starting, .recording, .pausing, .onBreak, .stopping: return true
        case .idle, .failed: return false
        }
    }

    func elapsed(at date: Date) -> TimeInterval {
        guard phase == .recording || phase == .pausing || phase == .stopping, let startedAt else { return 0 }
        return max(0, date.timeIntervalSince(startedAt))
    }

    func start(course: Course?) async {
        guard let model, phase == .idle || phase == .onBreak || isFailed else { return }
        // a break, or a failed attempt to come back from one for the same course, continues that session
        let joining = phase == .onBreak || (isFailed && breakSession != nil && breakSession?.courseID == course?.id)
        phase = .starting
        var startedClient: RecorderClient?
        do {
            let library = model.library
            let now = Date()
            var session: Session
            if joining, let current = breakSession {
                session = library.reload(current) ?? current
            } else if let course {
                let week = library.settings().semester.map { model.schedule.week(of: now, semester: $0) }
                session = try library.lectureSession(course: course, date: now, week: week)
            } else {
                session = try library.newMeeting(title: L("meeting.untitled"), date: now)
            }
            let file = library.newRecordingFile(in: session, start: now)
            let client = RecorderClient(helper: RecorderClient.defaultHelper(),
                                        output: library.folder(of: session).appendingPathComponent(file))
            client.onEvent = { [weak self, weak client] event in
                Task { @MainActor in
                    guard let self, let client else { return }
                    self.handle(event, from: client)
                }
            }
            let simulate = ProcessInfo.processInfo.environment["LECTERN_SIMULATE"].flatMap(Double.init)
            let started = try await client.start(simulate: simulate)
            startedClient = client
            var info = RecordingInfo(file: file, start: started, inProgress: true)
            info.recorderPID = client.pid
            session.recordings.append(info)
            try library.save(session)
            self.client = client
            self.session = session
            self.course = course ?? model.course(session.courseID)
            self.file = file
            startedAt = started
            breakStartedAt = nil
            breakSession = nil
            if !joining { notes = [] }
            startTicking()
            withAnimation(Theme.ease) { phase = .recording }
            model.reload()
            // the helper may have quit between saying it was ready and being taken over here
            if let early = endedEarly, early.client == ObjectIdentifier(client) {
                endedEarly = nil
                apply(early.report)
                close()
            }
        } catch {
            // a helper that did start must not keep recording with nobody to stop it
            if let startedClient { _ = await startedClient.stop() }
            phase = .failed(error.localizedDescription)
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    func addNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .recording, !trimmed.isEmpty, let file, var session, let model else { return }
        let marker = Marker(recording: file, time: elapsed(at: Date()), text: trimmed)
        session = model.library.reload(session) ?? session
        session.markers.append(marker)
        try? model.library.save(session)
        self.session = session
        withAnimation(Theme.ease) { notes.append(marker) }
    }

    /// Ends this half of the lecture; `resume` starts the next recording in the same session.
    func takeBreak() async {
        guard phase == .recording else { return }
        phase = .pausing
        await finishRecording()
        guard phase == .pausing else { return }
        if stopAfterPause {
            close()
            return
        }
        breakSession = session
        withAnimation(Theme.ease) {
            phase = .onBreak
            breakStartedAt = Date()
        }
    }

    func resume() async {
        guard phase == .onBreak else { return }
        await start(course: course)
    }

    func stop() async {
        switch phase {
        case .onBreak:
            close()
        case .pausing:
            // the break finishes closing the recording, then ends the lecture
            stopAfterPause = true
        case .recording:
            phase = .stopping
            await finishRecording()
            close()
        default:
            break
        }
    }

    private func close() {
        let finished = session
        ticker?.invalidate()
        ticker = nil
        phase = .idle
        startedAt = nil
        breakStartedAt = nil
        breakSession = nil
        stopAfterPause = false
        client = nil
        model?.reload()
        if let finished, let model {
            let fresh = model.library.reload(finished) ?? finished
            model.open(fresh)
            // the lecture is over: transcript and notes start right away
            model.processing.process(fresh)
        }
    }

    private func finishRecording() async {
        let report = await client?.stop()
        apply(report)
    }

    private func apply(_ report: RecordingReport?) {
        guard let model, let file, let current = session else { return }
        var session = model.library.reload(current) ?? current
        if let index = session.recordings.firstIndex(where: { $0.file == file }) {
            session.recordings[index].inProgress = false
            session.recordings[index].recorderPID = nil
            if let report {
                session.recordings[index].duration = report.duration
                session.recordings[index].device = report.device
                session.recordings[index].gaps = report.gaps
                session.recordings[index].deviceChanges = report.deviceChanges
                session.recordings[index].problem = report.status == .failed ? report.error : nil
            }
        }
        try? model.library.save(session)
        self.session = session
    }

    private func handle(_ event: RecorderClient.Event, from sender: RecorderClient) {
        guard sender === client else {
            // only an end matters before `start` has taken the helper over; it is applied there
            if case .ended(let report) = event, phase == .starting {
                endedEarly = (ObjectIdentifier(sender), report)
            }
            return
        }
        switch event {
        case .level(_, let peak):
            // dBFS to 0...1 over the last 60 dB
            let value = CGFloat(min(1, max(0, (peak + 60) / 60)))
            levels.removeFirst()
            levels.append(value)
        case .gap:
            break
        case .ended(let report):
            // the helper stopped on its own (error or maximum length)
            apply(report)
            close()
        }
    }
}

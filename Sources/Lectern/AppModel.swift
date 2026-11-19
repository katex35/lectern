import AppKit
import AVFoundation
import Foundation
import LecternCore
import Observation
import SwiftUI

enum Screen: Hashable {
    case home
    case recording
    case session(SessionRef)
    /// Every recording, or one course's, or the meetings.
    case archive(ArchiveFilter)
    /// The week's lectures and the dates ahead.
    case schedule
    /// Practice cards from a course's questions; nil is the course with the nearest exam.
    case exam(String?)
}

enum ArchiveFilter: Hashable {
    case all
    case course(String)
    case meetings

    func includes(_ session: Session) -> Bool {
        switch self {
        case .all: return true
        case .course(let id): return session.courseID == id
        case .meetings: return session.kind == .meeting
        }
    }
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

extension Session {
    /// Folder names repeat across courses ("2026-10-13 Week 04"); lists key sessions by this.
    var ref: SessionRef { SessionRef(self) }
}

@MainActor @Observable
final class AppModel {
    let library: Library
    let schedule = Schedule()
    let recorder = RecordingController()
    let processing = ProcessingCenter()
    let chat = ChatCenter()
    let meetings = MeetingWatcher()
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

    /// The model of this run, for the app delegate (quitting ends an automatic recording first).
    static weak var current: AppModel?

    init(library: Library) {
        self.library = library
        Self.current = self
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
        // lectures imported before lengths were read from the files
        if library.completeDurations(sessions) > 0 { reload() }
        refreshAccounts()
        Reminders.shared.start(self)
        // a recorder that outlived the last run is taken over; what a crash left behind (recordings
        // never closed, computer audio not mixed in yet) is finished
        let adopted = recorder.adoptRunningRecording()
        meetings.start(self, adopted: adopted)
        MeetingControl.listen(self)
        Task {
            if await library.recoverRecordings() > 0 { reload() }
        }
        // courses that came in without a cover get one now that an account may draw it
        Task { await Covers.drawMissing(model: self) }
    }

    func refreshAccounts() {
        Providers.accountsChanged()
        noteModelName = ProviderSummary.noteModel()
        // lectures written before dates were looked for, now that something may be able to read them
        processing.findMissingDates()
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

    func go(to screen: Screen) {
        withAnimation(Theme.ease) { self.screen = screen }
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

    // MARK: dates said in lectures

    /// Dates found in lectures that are still ahead and not decided on, soonest first. A date said in
    /// several lectures shows once, from the latest; one the course already has does not show.
    var mentionedDates: [(session: Session, date: MentionedDate)] {
        // read from the files once per reload, not on every redraw
        let day = Calendar.current.startOfDay(for: Date())
        if let cached = mentionedCache, cached.revision == revision, cached.day == day { return cached.dates }
        let dates = readMentionedDates()
        mentionedCache = (revision, day, dates)
        return dates
    }

    @ObservationIgnored private var mentionedCache: (revision: Int, day: Date, dates: [(session: Session, date: MentionedDate)])?

    private func readMentionedDates() -> [(session: Session, date: MentionedDate)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var found: [(session: Session, date: MentionedDate)] = []
        // newest lectures first, so the first of each kind of date is the latest mention
        for session in sessions where session.courseID != nil {
            let known = course(session.courseID)?.events ?? []
            for date in library.mentionedDates(of: session) where date.decision == .pending && date.date >= today {
                let same = { (other: Date, kind: CourseDate.Kind) in kind == date.kind && calendar.isDate(other, inSameDayAs: date.date) }
                if known.contains(where: { same($0.date, $0.kind) }) { continue }
                if found.contains(where: { $0.session.courseID == session.courseID && same($0.date.date, $0.date.kind) }) { continue }
                found.append((session, date))
            }
        }
        return found.sorted { $0.date.date < $1.date.date }
    }

    /// Adds a found date to its course's dates, where reminders pick it up, or sets it aside; the same
    /// date said in the course's other lectures is decided with it.
    func decide(_ date: MentionedDate, in session: Session, add: Bool) {
        let calendar = Calendar.current
        do {
            try library.decide(date, in: session, add: add)
            for other in sessions where other.courseID == session.courseID && other.ref != session.ref {
                for repeated in library.mentionedDates(of: other)
                where repeated.decision == .pending && repeated.kind == date.kind && calendar.isDate(repeated.date, inSameDayAs: date.date) {
                    // already on the course once; the others are only marked
                    try library.decide(repeated, in: other, add: false)
                }
            }
            withAnimation(Theme.ease) { reload() }
            if add {
                Task { await Reminders.shared.plan() }
                show(UserDefaults.standard.bool(forKey: Reminders.enabledKey) ? L("dates.addedReminded") : L("dates.added"))
            }
        } catch {
            show(error.localizedDescription)
        }
    }

    /// Opens the lecture at the moment a date was said.
    func play(_ date: MentionedDate, in session: Session) {
        jump = Jump(session: SessionRef(session), source: .transcript, time: date.at)
        open(session)
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
    /// The computer's audio in a meeting: recorded next to the microphone and mixed in at the end.
    enum SystemAudio: Equatable {
        case off
        /// Asked for; nothing has arrived yet (macOS may still be asking for permission).
        case waiting
        case recording
        case problem(String)
    }

    private(set) var systemAudio: SystemAudio = .off
    /// Set while the recording is one that began on its own (a meeting app opened the microphone).
    private(set) var automatic: AutomaticRecording?
    /// How a recording that began on its own ended, with its session when something was recorded.
    var onAutomaticEnd: ((AutoRecordPolicy.End, Session?) -> Void)?
    private var endedBy = AutoRecordPolicy.End.finished
    /// The call ended while the recording was still starting (macOS was asking for the microphone).
    private var stopOnceStarted = false
    /// The helper while it is starting, so quitting can end it.
    private var startingClient: RecorderClient?
    /// The app is quitting: what is closed now is not processed now.
    private var quitting = false
    private var ticks = 0
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
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.everySecond() }
        }
        // also while a menu is open: an automatic recording lives on the heartbeat sent from here
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func everySecond() {
        tick = Date()
        ticks += 1
        guard phase == .recording, let client else { return }
        // an automatic recording ends itself when the app stops saying it is still there
        if ticks % 30 == 0 { client.heartbeat() }
        // a recorder taken over after a restart sends no events: notice when it has ended on its own
        if client.isAttached, !client.isRunning {
            apply(client.sidecarReport())
            close()
        }
    }

    /// After a restart: a recorder that is still writing is taken over, so it can be stopped from the
    /// app again. Returns what a recording that began on its own needs to go on ending with its call.
    @discardableResult
    func adoptRunningRecording() -> AutomaticRecording? {
        guard let model, phase == .idle else { return nil }
        for session in model.sessions {
            let folder = model.library.folder(of: session)
            for recording in session.recordings where recording.inProgress {
                guard let pid = recording.recorderPID,
                      let client = RecorderClient.attach(pid: pid, output: folder.appendingPathComponent(recording.file)) else { continue }
                self.client = client
                self.session = session
                self.course = model.course(session.courseID)
                self.file = recording.file
                automatic = recording.automatic
                startedAt = recording.start
                notes = session.markers.filter { $0.recording == recording.file }
                if model.library.isDiscarded(session), automatic != nil {
                    // refused before the last run ended: finish throwing it away
                    phase = .recording
                    Task { await discardAutomatic() }
                    return nil
                }
                client.heartbeat()
                startTicking()
                phase = .recording
                return recording.automatic
            }
        }
        return nil
    }

    var isIdle: Bool { phase == .idle }

    /// Nothing is being recorded and a recording may begin (also after a start that failed).
    var canStart: Bool { phase == .idle || isFailed }

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

    /// A meeting with a name of its own; `automatic` when it began by itself.
    struct MeetingStart {
        var title: String
        var automatic: AutomaticRecording?
    }

    func start(course: Course?, meeting: MeetingStart? = nil) async {
        // A recording that begins on its own never takes over anything the user started or is looking
        // at (another recording, a break, a failure). Whoever asked for it is always told.
        if meeting?.automatic != nil, phase != .idle {
            onAutomaticEnd?(.failed, nil)
            return
        }
        guard let model, phase == .idle || phase == .onBreak || isFailed else { return }
        // a break, or a failed attempt to come back from one for the same course, continues that session
        let joining = phase == .onBreak || (isFailed && breakSession != nil && breakSession?.courseID == course?.id)
        phase = .starting
        automatic = meeting?.automatic
        endedBy = .finished
        stopOnceStarted = false
        var startedClient: RecorderClient?
        var newSession: Session?
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
                session = try library.newMeeting(title: meeting?.title ?? L("meeting.untitled"), date: now)
            }
            newSession = joining || course != nil ? nil : session
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
            // a meeting is recorded with the microphone the call itself uses, with the other side
            // (what the Mac plays) next to it, and may run longer than a lecture
            let isMeeting = session.kind == .meeting
            let withSystemAudio = isMeeting && MeetingSettings.recordsSystemAudio
            systemAudio = withSystemAudio ? .waiting : .off
            startingClient = client
            defer { startingClient = nil }
            let started = try await client.start(
                deviceID: isMeeting && simulate == nil ? AVCaptureDevice.default(for: .audio)?.uniqueID : nil,
                maxDuration: isMeeting ? MeetingSettings.maxDuration : nil, simulate: simulate,
                systemAudio: withSystemAudio, watchdog: meeting?.automatic != nil ? MeetingSettings.watchdog : nil)
            startedClient = client
            var info = RecordingInfo(file: file, start: started, inProgress: true)
            info.recorderPID = client.pid
            // as it stands now: "Is this a meeting?" may have been answered while the recorder was starting
            info.automatic = automatic
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
            } else if stopOnceStarted {
                stopOnceStarted = false
                await stopAutomatic(quitting: quitting)
            }
        } catch {
            // a helper that did start must not keep recording with nobody to stop it
            if let startedClient { _ = await startedClient.stop() }
            systemAudio = .off
            if meeting?.automatic != nil {
                // nobody asked for this recording: no failure on screen and no empty meeting left behind
                if let newSession { try? FileManager.default.removeItem(at: model.library.folder(of: newSession)) }
                automatic = nil
                phase = .idle
                model.reload()
                onAutomaticEnd?(.failed, nil)
            } else {
                phase = .failed(error.localizedDescription)
            }
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
        // a recording that began on its own ends with its call; a break would leave nobody to end it
        guard phase == .recording, automatic == nil else { return }
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

    /// The call is over: ends a recording that began on its own. `quitting`: the app is about to
    /// quit, so notes are not started now; they are written when the user asks for them.
    func stopAutomatic(quitting: Bool = false) async {
        if automatic != nil, phase == .starting { stopOnceStarted = true }
        guard automatic != nil, phase == .recording else { return }
        phase = .stopping
        if quitting { self.quitting = true }
        // written down before anything else: a crash from here on must not bring a refused recording back
        if endedBy == .rejected, let session { model?.library.markDiscarded(session) }
        await finishRecording()
        close()
    }

    /// The app is about to quit: a recording that began on its own is ended and added first, whatever
    /// it is doing. Its notes are not started now.
    func settleAutomaticForQuit() async {
        guard automatic != nil else { return }
        quitting = true
        func wait(upTo seconds: Double, while condition: () -> Bool) async {
            var left = Int(seconds * 10)
            while condition(), left > 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                left -= 1
            }
        }
        if phase == .starting {
            // usually a moment; when macOS is still asking for the microphone, the helper is ended instead
            stopOnceStarted = true
            await wait(upTo: 3) { self.phase == .starting }
            if phase == .starting, let pid = startingClient?.pid { kill(pid, SIGKILL) }
            await wait(upTo: 3) { self.phase == .starting }
        }
        if phase == .recording { await stopAutomatic(quitting: true) }
        await wait(upTo: 900) { self.phase == .stopping }
    }

    /// A call too short to be sure of (a voice message, a microphone opened by mistake): kept, but its
    /// notes wait for the user like those of a recording nobody confirmed.
    func holdAutomaticProcessing() {
        guard automatic?.confirmed == true, phase == .recording, let model, let file, let current = session else { return }
        automatic?.confirmed = false
        var session = model.library.reload(current) ?? current
        if let index = session.recordings.firstIndex(where: { $0.file == file }) {
            session.recordings[index].automatic?.confirmed = false
            try? model.library.save(session)
            self.session = session
        }
    }

    /// The answer to "Is this a meeting?" was no: the recording ends and goes to the Trash.
    func discardAutomatic() async {
        guard refuseAutomatic() else { return }
        await stopAutomatic()
    }

    /// Takes the "no" down at once, before anything is stopped: from here on the recording is thrown
    /// away however it ends (the call ending by itself, a Stop already under way, a crash). While the
    /// recorder is still starting there is no folder to mark yet; the answer is kept and applied then.
    @discardableResult
    func refuseAutomatic() -> Bool {
        guard automatic != nil, !isIdle else { return false }
        endedBy = .rejected
        if phase == .recording || phase == .stopping, let session { model?.library.markDiscarded(session) }
        return true
    }

    /// The answer to "Is this a meeting?" was yes: the recording is processed like any other.
    func confirmAutomatic() {
        guard automatic != nil else { return }
        automatic?.confirmed = true
        // still starting: the answer is saved with the recording once it exists
        guard phase == .recording, let model, let file, let current = session else { return }
        var session = model.library.reload(current) ?? current
        if let index = session.recordings.firstIndex(where: { $0.file == file }) {
            session.recordings[index].automatic?.confirmed = true
            try? model.library.save(session)
            self.session = session
        }
    }

    func stop() async {
        if automatic != nil, endedBy != .rejected { endedBy = .stoppedByUser }
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
        // once per recording: the helper ending on its own and a Stop in progress may both get here
        guard phase != .idle else { return }
        let finished = session
        ticker?.invalidate()
        ticker = nil
        phase = .idle
        startedAt = nil
        breakStartedAt = nil
        breakSession = nil
        stopAfterPause = false
        client = nil
        systemAudio = .off
        let wasAutomatic = automatic, how = endedBy, wasQuitting = quitting
        automatic = nil
        endedBy = .finished
        quitting = false
        var closed: Session?
        if how == .rejected, wasAutomatic != nil, let finished, let model {
            // "not a meeting": nothing of it stays in the library
            model.library.discard(finished)
            session = nil
            model.reload()
            onAutomaticEnd?(how, nil)
            return
        }
        model?.reload()
        if let finished, let model {
            let fresh = model.library.reload(finished) ?? finished
            closed = fresh
            // Asked for and missing: say so once, the recording itself is fine. A call that began on
            // its own and in which the Mac played nothing was most likely not allowed to be heard.
            let heard = fresh.recordings.last?.systemAudio?.status
            if heard == .failed || (heard == .silent && wasAutomatic != nil) {
                model.show(L("notice.systemAudio.missing"))
            }
            // a recording that began on its own does not pull the window to itself
            if wasAutomatic == nil { model.open(fresh) }
            // the lecture is over: transcript and notes start right away. A recording nobody confirmed
            // to be a meeting waits until the user asks for them.
            if wasAutomatic?.confirmed != false, !wasQuitting { model.processing.process(fresh) }
        }
        if wasAutomatic != nil { onAutomaticEnd?(how, closed) }
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
                session.recordings[index].systemAudio = report.systemAudio
                // anything but a clean end is kept as a problem: the next launch repairs such a file
                session.recordings[index].problem = report.status == .finished ? nil
                    : report.error ?? "The recording was interrupted."
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
        case .systemAudioStarted:
            systemAudio = .recording
        case .systemAudioProblem(let message):
            systemAudio = .problem(message)
        case .ended(let report):
            // the helper stopped on its own (error or maximum length)
            apply(report)
            close()
        }
    }
}

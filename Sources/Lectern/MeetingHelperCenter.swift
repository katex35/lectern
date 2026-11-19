import AppKit
import LecternCore
import Observation
import SwiftUI

/// What the user chose for the live helper, kept in the app's defaults.
enum HelperSettings {
    static let modeKey = "helper.mode"
    static let sensitivityKey = "helper.sensitivity"

    /// The helper hears what the Mac plays, which is recorded since macOS 14.2.
    static var isAvailable: Bool { SystemAudioRecorder.isSupported }

    static var mode: MeetingHelper.Setting {
        guard isAvailable, MeetingSettings.recordsSystemAudio else { return .off }
        return UserDefaults.standard.string(forKey: modeKey).flatMap(MeetingHelper.Setting.init) ?? .off
    }

    static var sensitivity: MeetingHelper.Sensitivity {
        UserDefaults.standard.string(forKey: sensitivityKey).flatMap(MeetingHelper.Sensitivity.init) ?? .medium
    }

    /// What the user wrote for the helper: who they are, what they work on, which questions to catch.
    static func notesURL(_ library: Library) -> URL { library.root.appendingPathComponent("helper.md") }
}

/// The live helper. While a meeting is recorded it listens in on what the Mac plays through the small
/// file the recorder keeps (`LiveAudioRing`), finds where a turn ends, and asks the model whether
/// something was asked and what to say. On the key it does the same for the last half minute.
///
/// Nothing leaves the Mac unless the helper is turned on: with the key, only the seconds before a
/// press; on its own, every turn. The user's own microphone is never sent. `MeetingHelper.maySend`
/// is the one place that decides.
@MainActor @Observable
final class MeetingHelperCenter {
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var ring: URL?
    @ObservationIgnored private var session: Session?
    /// Goes up whenever the meeting being listened to changes: an answer that comes back for an
    /// earlier one is dropped, never shown or logged in the next.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var detector: TurnDetector?
    @ObservationIgnored private var nextFrame = 0
    @ObservationIgnored private var lastSound = Date()
    @ObservationIgnored private var earlier: [String] = []
    /// The request in flight and what it is for.
    @ObservationIgnored private var working: (task: Task<Void, Never>, mode: MeetingHelper.Mode)?
    /// Turns that ended while the model was busy, oldest first, with when they ended.
    @ObservationIgnored private var waiting: [(turn: TurnDetector.Turn, ended: Date)] = []
    @ObservationIgnored private var offered: HelperReply?
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var panel: MeetingPanel?
    @ObservationIgnored private var panelToken = 0
    @ObservationIgnored private var saidNoAccount = false
    /// After a failure the helper stops asking on its own for a while (a quota, a dead line).
    @ObservationIgnored private var quietUntil = Date.distantPast
    @ObservationIgnored private var failures = 0
    /// True while a meeting is being listened to.
    private(set) var isListening = false

    /// How much of the call is sent on the key, and at most for one turn.
    static let keyWindow = 30.0
    static let longestTurn = 30.0
    /// A model that has not answered by then is not worth waiting for in a live call.
    static let patience: [MeetingHelper.Mode: Double] = [.asked: 15, .listening: 10]
    /// A turn that has waited longer than this for the model is about something already past.
    static let staleAfter = 20.0

    func start(_ model: AppModel) {
        self.model = model
    }

    /// A meeting is being recorded with what the Mac plays kept live at `ring`.
    func attach(ring: URL, session: Session) {
        detach()
        self.ring = ring
        self.session = session
        generation += 1
        detector = nil
        nextFrame = 0
        lastSound = Date()
        earlier = []
        failures = 0
        quietUntil = .distantPast
        isListening = true
        hotKey = GlobalHotKey(code: GlobalHotKey.helperKey.code, modifiers: GlobalHotKey.helperKey.modifiers) { [weak self] in
            self?.keyPressed()
        }
        if hotKey == nil, HelperSettings.mode != .off {
            // another app holds the key: say so instead of leaving it dead
            model?.show(L("helper.keyTaken", GlobalHotKey.helperKey.label))
        }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func detach() {
        generation += 1
        timer?.invalidate()
        timer = nil
        hotKey = nil
        working?.task.cancel()
        working = nil
        ring = nil
        session = nil
        waiting = []
        offered = nil
        isListening = false
        closePanel()
    }

    /// A recording that began on its own and still waits for "Is this a meeting?".
    private var unconfirmed: Bool { model?.recorder.automatic?.confirmed == false }

    private func allowed(_ mode: MeetingHelper.Mode) -> Bool {
        MeetingHelper.maySend(mode, setting: HelperSettings.mode, unconfirmedRecording: unconfirmed)
    }

    // MARK: listening

    private func tick() {
        guard let ring else { return }
        // Turns are followed whatever the setting, so turning the helper on in the middle of a call
        // works at once; nothing is sent unless `allowed` says so.
        guard let snapshot = LiveAudioRing.read(ring, from: nextFrame) else { return }
        if detector == nil { detector = TurnDetector(sampleRate: snapshot.sampleRate) }
        if snapshot.firstFrame > nextFrame {
            // read too late, part of the track is gone from the ring: start over from what is there
            detector?.reset(to: snapshot.firstFrame)
        }
        nextFrame = snapshot.endFrame
        var turns: [TurnDetector.Turn] = []
        if snapshot.samples.isEmpty {
            // nothing plays, so nothing arrives: the pause is counted from the clock
            if let turn = detector?.quiet(for: Date().timeIntervalSince(lastSound)) { turns.append(turn) }
        } else {
            lastSound = Date()
            turns = detector?.feed(snapshot.samples) ?? []
        }
        for turn in turns { heard(turn) }
    }

    /// One request at a time. A turn that ends while the model is busy waits its turn; a few may wait,
    /// and one that has waited too long is dropped rather than answered late.
    private func heard(_ turn: TurnDetector.Turn) {
        guard allowed(.listening), Date() >= quietUntil else { return }
        if working != nil {
            waiting.append((turn, Date()))
            if waiting.count > 3 { waiting.removeFirst(waiting.count - 3) }
        } else {
            run(.listening, turn: turn)
        }
    }

    /// The key was pressed (also called by the development check).
    func keyPressed() {
        guard ring != nil, allowed(.asked) else { return }
        // an offer on screen: the key opens it, nothing is sent again
        if let offered {
            self.offered = nil
            show(.answer(offered), for: 60, feedback: offered)
            return
        }
        // the user comes first: whatever was being asked on its own is dropped
        if let working {
            guard working.mode != .asked else { return }
            working.task.cancel()
            self.working = nil
        }
        waiting = []
        show(.listening, for: (Self.patience[.asked] ?? 15) + 2, feedback: nil)
        run(.asked, turn: nil)
    }

    private func run(_ mode: MeetingHelper.Mode, turn: TurnDetector.Turn?) {
        guard let ring, let model else { return }
        guard let listener = Providers.listener() else {
            // said once per meeting, and whenever the user asked
            if mode == .asked || !saidNoAccount { show(.problem(L("helper.needsGemini")), for: 12, feedback: nil) }
            saidNoAccount = true
            return
        }
        let snapshot: LiveAudioRing.Snapshot?
        if let turn {
            let length = min(turn.end - turn.start, Int(Self.longestTurn * (detector?.sampleRate ?? 16000)))
            snapshot = LiveAudioRing.read(ring, from: turn.end - length).map { found in
                var cut = found
                cut.samples = Array(found.samples.prefix(max(0, turn.end - found.firstFrame)))
                return cut
            }
        } else {
            snapshot = LiveAudioRing.read(ring, last: Self.keyWindow)
        }
        guard let snapshot, Double(snapshot.samples.count) / snapshot.sampleRate >= 0.3,
              let audio = try? AudioClip.m4a(snapshot.samples, sampleRate: snapshot.sampleRate) else {
            if mode == .asked { show(.problem(L("helper.nothingHeard")), for: 8, feedback: nil) }
            return
        }
        let notes = (try? String(contentsOf: HelperSettings.notesURL(model.library), encoding: .utf8)) ?? ""
        let prompt = MeetingHelper.prompt(.init(mode: mode, language: appLanguage, name: userFirstName, context: notes,
                                                earlier: earlier))
        let at = Double(snapshot.endFrame) / snapshot.sampleRate
        let generation = generation
        let patience = Self.patience[mode] ?? 10
        let task = Task { [weak self] in
            let outcome: Result<HelperReply, Error>
            do {
                let text = try await Self.withPatience(patience) {
                    try await listener.answer(prompt: prompt, audio: audio, mimeType: AudioClip.mimeType)
                }
                outcome = .success(try MeetingHelper.parse(text))
            } catch {
                outcome = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.finished(outcome, mode: mode, at: at, generation: generation)
        }
        working = (task, mode)
    }

    private func finished(_ outcome: Result<HelperReply, Error>, mode: MeetingHelper.Mode, at: Double, generation: Int) {
        // an answer for a meeting that is over, or was replaced by another, goes nowhere
        guard generation == self.generation, ring != nil else { return }
        working = nil
        defer {
            // the oldest turn still fresh enough is next
            waiting.removeAll { Date().timeIntervalSince($0.ended) > Self.staleAfter }
            if working == nil, !waiting.isEmpty, allowed(.listening), Date() >= quietUntil {
                run(.listening, turn: waiting.removeFirst().turn)
            }
        }
        switch outcome {
        case .failure(let error):
            // On its own the helper fails quietly (an error box in the middle of a call helps nobody)
            // and waits before it asks again: half a minute, then longer, up to five.
            failures += 1
            quietUntil = Date().addingTimeInterval(min(300, 30 * pow(2, Double(failures - 1))))
            waiting = []
            if mode == .asked { show(.problem(error.localizedDescription), for: 10, feedback: nil) }
            log(["at": at, "mode": mode.rawValue, "error": error.localizedDescription])
        case .success(let reply):
            failures = 0
            quietUntil = .distantPast
            if !reply.heard.isEmpty {
                earlier.append(reply.heard)
                if earlier.count > 8 { earlier.removeFirst(earlier.count - 8) }
            }
            let decision = MeetingHelper.decide(reply, mode: mode, sensitivity: HelperSettings.sensitivity)
            log(["at": at, "mode": mode.rawValue, "heard": reply.heard, "kind": reply.kind.rawValue, "forMe": reply.forMe,
                 "confidence": reply.confidence, "question": reply.question, "decision": "\(decision)",
                 "answer": reply.answer.map { ([$0.headline] + $0.points).joined(separator: " | ") } ?? ""])
            switch decision {
            case .show:
                offered = nil
                show(.answer(reply), for: 60, feedback: reply)
            case .offer:
                offered = reply
                show(.offer(reply), for: 20, feedback: nil)
            case .silent:
                if mode == .asked { show(.problem(L("helper.nothingHeard")), for: 8, feedback: nil) }
            }
        }
    }

    /// Runs `work`, giving up after `seconds`.
    private static func withPatience<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ProviderError.invalidResponse(L("helper.tooSlow"))
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: the panel

    private func show(_ content: HelperNotice.Content, for seconds: TimeInterval, feedback reply: HelperReply?) {
        panel?.dismiss()
        panelToken += 1
        let token = panelToken
        let notice = HelperNotice(content: content, notUseful: reply.map { reply in
            { [weak self] in
                self?.log(["feedback": "not useful", "question": reply.question])
                self?.closePanel()
            }
        }, close: { [weak self] in self?.closePanel() })
        let panel = MeetingPanel(content: notice)
        self.panel = panel
        panel.show()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.panelToken == token else { return }
            if case .offer = content { self.offered = nil }
            self.closePanel()
        }
    }

    private func closePanel() {
        panel?.dismiss()
        panel = nil
    }

    // MARK: the record

    /// Every answer and every "not useful" goes into `helper.jsonl` in the meeting's folder: what the
    /// helper heard and did, to look back at and to tune what counts as a question. It stays on the Mac.
    private func log(_ entry: [String: Any]) {
        guard let model, let session else { return }
        var entry = entry
        entry["time"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        let url = model.library.folder(of: session).appendingPathComponent("helper.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }

    /// The panels with made-up content, for the development screenshots.
    static var sampleNotices: [(name: String, notice: HelperNotice)] {
        let reply = HelperReply(
            heard: "", kind: .question, forMe: true, confidence: 0.9,
            question: "How many students took part in the pilot, and how did you measure the improvement?",
            gist: appLanguage == "tr" ? "Pilota kaç öğrenci katıldı, gelişmeyi nasıl ölçtünüz?" : "How many students were in the pilot, and how was progress measured?",
            answer: .init(headline: "42 students, measured before and after",
                          points: ["42 students from three schools took part in 2025.",
                                   "We ran the same skills test before and after the programme.",
                                   "I can send the full report after the call."]))
        return [("helper-answer", HelperNotice(content: .answer(reply), notUseful: {}, close: {})),
                ("helper-offer", HelperNotice(content: .offer(reply), close: {})),
                ("helper-listening", HelperNotice(content: .listening, close: {}))]
    }
}

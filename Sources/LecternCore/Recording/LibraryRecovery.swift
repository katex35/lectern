import Foundation

extension Library {
    /// How long the hidden copies of a mixed meeting are kept (the microphone alone, the computer's audio).
    public static let trackLifetime: TimeInterval = 7 * 24 * 3600

    /// Finishes what a crash or a power cut left behind. Run once at launch.
    ///
    /// - A recording still marked as in progress whose recorder is gone is repaired up to its last
    ///   fragment and closed. One whose recorder is still writing is left alone.
    /// - A meeting the user refused ("not a meeting") that was not thrown away yet goes to the Trash.
    /// - A recording that ended with a problem and is still in fragments is repaired.
    /// - Computer audio recorded next to a recording and not mixed in yet is mixed in.
    /// - The hidden copies of a mixed meeting are removed once all of them are older than `trackLifetime`.
    ///
    /// Returns how many sessions changed.
    @discardableResult
    public func recoverRecordings(now: Date = Date()) async -> Int {
        var changed = 0
        let all = courses().flatMap { sessions(ofCourse: $0.id) } + meetings()
        for session in all {
            let folder = folder(of: session)
            if isDiscarded(session) {
                let writing = session.recordings.contains { recording in
                    recording.recorderPID.map { RecorderClient.isRecording(pid: $0, output: folder.appendingPathComponent(recording.file)) } ?? false
                }
                // a recorder still writing it is taken over and stopped by the app first
                if !writing {
                    discard(session)
                    changed += 1
                }
                continue
            }
            // what this pass found out, by file name; the session is read again before it is saved
            var recovered: [String: RecordingInfo] = [:]
            var neverStarted: Set<String> = []
            for listed in session.recordings {
                var recording = listed
                let file = folder.appendingPathComponent(recording.file)
                if recording.inProgress {
                    if let pid = recording.recorderPID, RecorderClient.isRecording(pid: pid, output: file) { continue }
                    await close(&recording, file: file)
                    if !FileManager.default.fileExists(atPath: file.path) { neverStarted.insert(recording.file) }
                } else if recording.problem != nil, RecordingRecovery.isFragmented(file) {
                    // a recorder that had to be stopped by force left the file in fragments
                    if let repaired = try? await RecordingRecovery.repair(file) { recording.duration = repaired.duration }
                }
                TrackMerger.finishInterrupted(file)
                if TrackMerger.isPending(file) {
                    let system = RecordingTracks.system(for: file)
                    if RecordingRecovery.isFragmented(system) { _ = try? await RecordingRecovery.repair(system) }
                    recording.systemAudio = TrackMerger.mixPending(file)
                    if let length = AudioLength.seconds(of: file) { recording.duration = length }
                }
                removeOldCopies(of: file, now: now)
                if recording != listed { recovered[recording.file] = recording }
            }
            guard !recovered.isEmpty else { continue }
            // Repairs take a while and the app is in use meanwhile: a note may have been typed, another
            // recording started. Only the recordings handled here are written into the session as it is now.
            var fresh = reload(session) ?? session
            for index in fresh.recordings.indices {
                if let recording = recovered[fresh.recordings[index].file] { fresh.recordings[index] = recording }
            }
            // a recorder that died before any audio arrived left an entry without a file
            fresh.recordings.removeAll { neverStarted.contains($0.file) }
            if (try? save(fresh)) != nil { changed += 1 }
        }
        return changed
    }

    /// A recording whose recorder died: what is on disk becomes the recording.
    private func close(_ recording: inout RecordingInfo, file: URL) async {
        recording.inProgress = false
        recording.recorderPID = nil
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var interrupted = false
        if RecordingRecovery.isFragmented(file) {
            interrupted = true
            do {
                recording.duration = try await RecordingRecovery.repair(file).duration
            } catch {
                recording.problem = error.localizedDescription
            }
        }
        // the recorder may have finished on its own after the app was gone: its report says so
        let report = try? JSONStore.read(RecordingReport.self, from: RecordingReport.sidecar(for: file))
        if let report {
            if let start = report.start { recording.start = start }
            recording.device = report.device
            recording.gaps = report.gaps
            recording.deviceChanges = report.deviceChanges
            if let systemAudio = report.systemAudio { recording.systemAudio = systemAudio }
            if report.status == .failed, recording.problem == nil { recording.problem = report.error }
        }
        if let length = AudioLength.seconds(of: file) { recording.duration = length }
        if recording.problem == nil, interrupted || report?.status != .finished {
            recording.problem = "The recording was interrupted and was recovered up to its last moments."
        }
    }

    /// The copies go together, once the newest of them is old: removing one alone would change what
    /// the others mean.
    private func removeOldCopies(of file: URL, now: Date) {
        let fm = FileManager.default
        let copies = RecordingTracks.kept(for: file).filter { fm.fileExists(atPath: $0.path) }
        let newest = copies.compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }.max()
        guard let newest, now.timeIntervalSince(newest) > Self.trackLifetime else { return }
        copies.forEach { try? fm.removeItem(at: $0) }
    }
}

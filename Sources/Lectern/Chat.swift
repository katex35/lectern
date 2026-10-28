import Foundation
import LecternCore
import Observation
import SwiftUI

/// Conversations about lectures: a question goes to the connected account with the lecture's notes
/// and transcript, and the answer streams in.
@MainActor @Observable
final class ChatCenter {
    struct Thread {
        var entries: [ChatEntry] = []
        /// The answer while it is still coming.
        var streaming: String?
        var error: String?
        var needsAccount = false
    }

    private(set) var threads: [SessionRef: Thread] = [:]
    private var tasks: [SessionRef: Task<Void, Never>] = [:]
    weak var model: AppModel?

    func thread(of session: Session) -> Thread {
        threads[SessionRef(session)] ?? Thread()
    }

    /// Reads the conversation from the session folder the first time the lecture is opened.
    func load(_ session: Session) {
        let ref = SessionRef(session)
        guard threads[ref] == nil, let model else { return }
        threads[ref] = Thread(entries: LectureChat.load(from: model.folder(of: session)))
    }

    func isAnswering(_ session: Session) -> Bool {
        tasks[SessionRef(session)] != nil
    }

    func ask(_ question: String, in session: Session) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = SessionRef(session)
        guard !text.isEmpty, tasks[ref] == nil, let model else { return }
        let folder = model.folder(of: session)
        var thread = threads[ref] ?? Thread(entries: LectureChat.load(from: folder))
        thread.entries.append(ChatEntry(role: .user, text: text))
        thread.streaming = ""
        thread.error = nil
        thread.needsAccount = false
        threads[ref] = thread
        try? LectureChat.save(thread.entries, in: folder)

        let entries = thread.entries
        let course = model.course(session.courseID)
        let notes = model.text("notes.md", in: session)
        let transcript = model.text("transcript.txt", in: session)
        tasks[ref] = Task { [weak self] in
            defer { self?.tasks[ref] = nil }
            do {
                guard let writer = try await Providers.writer() else {
                    self?.finish(ref, folder: folder) { $0.needsAccount = true }
                    return
                }
                let request = LectureChat.request(model: writer.model, entries: entries, session: session, course: course,
                                                  notes: notes, transcript: transcript)
                var answer = ""
                for try await event in writer.provider.stream(request) {
                    if case .text(let piece) = event {
                        answer += piece
                        let shown = answer
                        self?.update(ref) { $0.streaming = shown }
                    }
                }
                let final = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.finish(ref, folder: folder) { $0.entries.append(ChatEntry(role: .assistant, text: final)) }
            } catch {
                self?.finish(ref, folder: folder) { $0.error = error.localizedDescription }
            }
        }
    }

    private func update(_ ref: SessionRef, _ change: (inout Thread) -> Void) {
        guard var thread = threads[ref] else { return }
        change(&thread)
        threads[ref] = thread
    }

    private func finish(_ ref: SessionRef, folder: URL, _ change: (inout Thread) -> Void) {
        withAnimation(Theme.ease) {
            update(ref) {
                $0.streaming = nil
                change(&$0)
            }
        }
        if let entries = threads[ref]?.entries { try? LectureChat.save(entries, in: folder) }
    }
}

/// The conversation tab: the student's questions on the right, answers as notes on the left.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let thread = model.chat.thread(of: session)
        let folder = model.folder(of: session)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(thread.entries.enumerated()), id: \.offset) { _, entry in
                if entry.role == .user {
                    Text(entry.text)
                        .font(.system(size: 14.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color(hex: 0xF4F4F4)))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .textSelection(.enabled)
                } else {
                    MarkdownText(source: entry.text, folder: folder)
                }
            }
            if let streaming = thread.streaming {
                if streaming.isEmpty {
                    PulsingDot(active: true, color: Theme.tertiary)
                } else {
                    MarkdownText(source: streaming, folder: folder)
                }
            }
            if thread.needsAccount {
                HStack(spacing: 6) {
                    Text(L("session.askNeedsAccount"))
                    SettingsLink { Text(L("session.openSettings")).underline() }.buttonStyle(.plain)
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            }
            if let error = thread.error {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.record)
            }
        }
    }
}

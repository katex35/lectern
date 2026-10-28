import Foundation
import LecternCore
import Observation
import SwiftUI

/// The services that transcribe and write, from the accounts in Settings.
@MainActor
enum Providers {
    static let credentials = Credentials(store: KeychainStore(service: SettingsView.keychainService))
    /// One session for the whole app: refresh tokens rotate, and two sessions refreshing the same
    /// token would end the sign-in.
    private static var chatGPT: (subject: String, session: ChatGPTSession)?

    /// Development: `LECTERN_FAKE_AI` runs the whole pipeline on stand-ins, without any account.
    private static let fake = ProcessInfo.processInfo.environment["LECTERN_FAKE_AI"] != nil

    static func transcriber() -> (any Transcribing)? {
        if fake { return Snapshots.FakeTranscriber() }
        guard let key = (try? credentials.apiKey(for: .gemini)) ?? nil else { return nil }
        return GeminiTranscriber(apiKey: key)
    }

    /// The first connected service in the order the top bar names it, with the model to write with.
    static func writer() async throws -> SessionProcessor.Writer? {
        if fake { return SessionProcessor.Writer(provider: Snapshots.FakeWriter(), model: "fake") }
        if let account = (try? credentials.chatGPTAccount()) ?? nil, account.canUsePlan {
            return try await pick(OpenAIProvider(credential: .chatGPT(chatGPTSession(account))))
        }
        if let key = (try? credentials.apiKey(for: .anthropic)) ?? nil {
            return SessionProcessor.Writer(provider: AnthropicProvider(apiKey: key), model: saved(.anthropic) ?? AnthropicProvider.defaultModel)
        }
        if let key = (try? credentials.apiKey(for: .gemini)) ?? nil {
            return try await pick(GeminiProvider(apiKey: key))
        }
        if let key = (try? credentials.apiKey(for: .openAI)) ?? nil {
            return try await pick(OpenAIProvider(credential: .apiKey(key)))
        }
        if let address = UserDefaults.standard.string(forKey: "endpoint.url"), let url = URL(string: address), url.host != nil {
            let key = (try? credentials.endpointKey("default")) ?? nil
            return try await pick(OpenAICompatibleProvider(baseURL: url, apiKey: key))
        }
        return nil
    }

    static let notesLanguageKey = "notes.language"

    /// The language notes are written in: the one chosen in Settings, else the app's.
    static var notesLanguage: String {
        UserDefaults.standard.string(forKey: notesLanguageKey).flatMap { $0.isEmpty ? nil : $0 } ?? appLanguage
    }

    static func modelKey(_ kind: ProviderKind) -> String { "notes.model.\(kind.rawValue)" }

    /// The service that writes notes, the models it offers and the one in use, for Settings.
    static func writerChoices() async -> (kind: ProviderKind, models: [String], current: String)? {
        guard let writer = (try? await writer()) ?? nil,
              let models = try? await writer.provider.models().map(\.id).filter({ !$0.contains("transcribe") }) else { return nil }
        let listed = models.contains(writer.model) ? models : [writer.model] + models
        return (writer.provider.kind, listed, writer.model)
    }

    /// Forgets the shared ChatGPT session after a sign-in or sign-out in Settings.
    static func accountsChanged() {
        chatGPT = nil
    }

    private static func chatGPTSession(_ account: ChatGPTAccount) -> ChatGPTSession {
        if let chatGPT, chatGPT.subject == account.subject { return chatGPT.session }
        let store = credentials
        let session = ChatGPTSession(account: account, auth: ChatGPTAuth(appName: "Lectern", hostID: account.hostID)) { updated in
            try? store.setChatGPTAccount(updated)
        }
        chatGPT = (account.subject, session)
        return session
    }

    private static func saved(_ kind: ProviderKind) -> String? {
        UserDefaults.standard.string(forKey: modelKey(kind))
    }

    /// The model chosen in Settings, else a sensible one from what the account lists.
    private static func pick(_ provider: any LanguageModelProvider) async throws -> SessionProcessor.Writer? {
        let models = try await retrying { try await provider.models() }.map(\.id).filter { !$0.contains("transcribe") }
        if let saved = saved(provider.kind), models.contains(saved) {
            return SessionProcessor.Writer(provider: provider, model: saved)
        }
        let choice: String?
        switch provider.kind {
        case .gemini:
            choice = models.first { $0.contains("pro") } ?? models.first { $0.contains("flash") && !$0.contains("lite") } ?? models.first
        case .openAI:
            choice = models.first { !$0.contains("mini") && !$0.contains("nano") } ?? models.first
        default:
            // the plan's own picker and local servers list their main model first
            choice = models.first
        }
        return choice.map { SessionProcessor.Writer(provider: provider, model: $0) }
    }
}

/// Turns finished recordings into transcripts, notes and questions, one run per session at a time.
@MainActor @Observable
final class ProcessingCenter {
    enum State: Equatable {
        case running(ProcessingProgress)
        /// Transcription needs a Gemini key.
        case needsGemini
        /// The transcript is there; notes need a connected account.
        case needsWriter
        case failed(String)
    }

    private(set) var states: [SessionRef: State] = [:]
    private var tasks: [SessionRef: Task<Void, Never>] = [:]
    /// Asked for again while running (a new recording ended meanwhile): run once more after.
    private var again: Set<SessionRef> = []
    weak var model: AppModel?

    func state(of session: Session) -> State? {
        states[SessionRef(session)]
    }

    func isRunning(_ session: Session) -> Bool {
        tasks[SessionRef(session)] != nil
    }

    /// Something can still be made: a recording not in the transcript yet, or notes behind the transcript.
    func hasWork(_ session: Session, in model: AppModel) -> Bool {
        guard session.recordings.contains(where: { !$0.inProgress }), !session.isRecording else { return false }
        return !SessionProcessor.isUpToDate(session, in: model.library)
    }

    private var sweeping: Task<Void, Never>?

    /// Reads the last three weeks' lectures for dates when they were transcribed before dates were
    /// looked for (imports, older versions), one at a time and only when a service can write.
    func findMissingDates() {
        guard sweeping == nil, let model else { return }
        let cutoff = Date().addingTimeInterval(-21 * 86_400)
        let library = model.library
        let due = model.sessions.filter { $0.date >= cutoff && SessionProcessor.needsDates($0, in: library) }
        guard !due.isEmpty else { return }
        sweeping = Task { [weak self] in
            defer { self?.sweeping = nil }
            guard let writer = (try? await Providers.writer()) ?? nil else { return }
            let processor = SessionProcessor(library: library, transcriber: nil, writer: writer, notesLanguage: Providers.notesLanguage)
            for session in due {
                guard let self, !Task.isCancelled else { return }
                // a lecture being processed reads its dates in that run
                if self.tasks[SessionRef(session)] != nil { continue }
                do {
                    try await processor.findDates(session, course: self.model?.course(session.courseID))
                } catch {
                    // the service is out of reach or over its limit; the rest wait for the next launch
                    return
                }
                self.model?.reload()
            }
        }
    }

    func process(_ session: Session) {
        let ref = SessionRef(session)
        guard let model else { return }
        guard tasks[ref] == nil else {
            again.insert(ref)
            return
        }
        let library = model.library
        let course = model.course(session.courseID)
        states[ref] = .running(.preparing)
        tasks[ref] = Task { [weak self] in
            defer {
                self?.tasks[ref] = nil
                // pick up the recordings that ended while this run was going
                if let self, self.again.remove(ref) != nil, let fresh = self.model?.session(ref) {
                    self.process(fresh)
                }
            }
            do {
                let processor = SessionProcessor(library: library, transcriber: Providers.transcriber(),
                                                 findWriter: { try await Providers.writer() }, notesLanguage: Providers.notesLanguage)
                let outcome = try await processor.run(session, course: course) { progress in
                    Task { @MainActor in
                        guard let self, case .running = self.states[ref] else { return }
                        withAnimation(Theme.quick) { self.states[ref] = .running(progress) }
                    }
                }
                withAnimation(Theme.ease) {
                    self?.states[ref] = outcome.needsTranscriber ? .needsGemini : outcome.needsWriter ? .needsWriter : nil
                }
                // notes give the lecture a topic, and the topic its own cover
                if let model = self?.model, let fresh = model.session(ref) {
                    Task { await Covers.draw(for: fresh, model: model) }
                }
            } catch {
                withAnimation(Theme.ease) { self?.states[ref] = .failed(error.localizedDescription) }
            }
            self?.model?.reload()
        }
    }
}

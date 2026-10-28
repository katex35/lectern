import AppKit
import LecternCore
import SwiftUI

struct SettingsView: View {
    static let keychainService = "app.lectern"
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            AccountsPane()
                .tabItem { Label(L("settings.accounts"), systemImage: "person.crop.circle") }
            GeneralPane()
                .tabItem { Label(L("settings.general"), systemImage: "gearshape") }
        }
        .frame(width: 620, height: 520)
    }
}

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            LabeledContent(L("settings.library")) {
                HStack {
                    Text(model.library.root.path)
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(L("settings.showInFinder")) { NSWorkspace.shared.activateFileViewerSelecting([model.library.root]) }
                }
            }
            LabeledContent(L("settings.language")) {
                Text(Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "")
                    .foregroundStyle(Theme.secondary)
            }
            SemesterSection()
        }
        .formStyle(.grouped)
    }
}

/// Term dates: week numbers of lectures count from the start.
private struct SemesterSection: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var hasEnd = false
    @State private var loaded = false

    var body: some View {
        Section(L("settings.semester")) {
            TextField(L("settings.semester.name"), text: $name, prompt: Text(L("settings.semester.namePrompt")))
            DatePicker(L("settings.semester.start"), selection: $start, displayedComponents: .date)
            Toggle(L("settings.semester.hasEnd"), isOn: $hasEnd)
            if hasEnd {
                DatePicker(L("settings.semester.end"), selection: $end, in: start..., displayedComponents: .date)
            }
        }
        .task {
            if let semester = model.library.settings().semester {
                name = semester.name
                start = semester.start
                if let last = semester.end {
                    end = last
                    hasEnd = true
                }
            }
            loaded = true
        }
        .onChange(of: name) { save() }
        .onChange(of: start) { save() }
        .onChange(of: end) { save() }
        .onChange(of: hasEnd) { save() }
    }

    private func save() {
        guard loaded else { return }
        var settings = model.library.settings()
        settings.semester = Semester(name: name.trimmingCharacters(in: .whitespaces), start: start, end: hasEnd ? end : nil)
        try? model.library.save(settings)
    }
}

private struct AccountsPane: View {
    @Environment(AppModel.self) private var model
    private let credentials = Credentials(store: KeychainStore(service: SettingsView.keychainService))

    var body: some View {
        Form {
            Section {
                ChatGPTRow(credentials: credentials)
            } footer: {
                Text(L("settings.chatgpt.footer")).foregroundStyle(Theme.tertiary)
            }
            Section {
                KeyRow(kind: .gemini, title: "Gemini", hint: L("settings.gemini.hint"),
                       link: URL(string: "https://aistudio.google.com/apikey")!, credentials: credentials)
                KeyRow(kind: .anthropic, title: "Claude", hint: L("settings.claude.hint"),
                       link: URL(string: "https://platform.claude.com/settings/keys")!, credentials: credentials)
                KeyRow(kind: .openAI, title: "OpenAI", hint: L("settings.openai.hint"),
                       link: URL(string: "https://platform.openai.com/api-keys")!, credentials: credentials)
            }
            Section {
                EndpointRow(credentials: credentials)
            } footer: {
                Text(L("settings.endpoint.footer")).foregroundStyle(Theme.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ChatGPTRow: View {
    @Environment(AppModel.self) private var model
    let credentials: Credentials
    @State private var account: ChatGPTAccount?
    @State private var working = false
    @State private var message: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "ChatGPT").font(.system(size: 14, weight: .semibold))
                Text(status).font(.system(size: 12)).foregroundStyle(account?.tokens != nil ? Color(hex: 0x047857) : Theme.tertiary)
            }
            Spacer()
            if working { ProgressView().controlSize(.small) }
            if account?.tokens != nil {
                Button(L("settings.signOut")) { Task { await signOut() } }
            } else {
                Button(L("settings.chatgpt.signIn")) { Task { await signIn() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
            }
        }
        .task { account = try? credentials.chatGPTAccount() }
    }

    private var status: String {
        if let message { return message }
        guard let account, account.tokens != nil else { return L("settings.notConnected") }
        if !account.canUsePlan { return L("settings.chatgpt.noPlan") }
        return L("settings.connected", account.email ?? "ChatGPT")
    }

    private func auth() throws -> ChatGPTAuth {
        ChatGPTAuth(appName: "Lectern", hostID: try credentials.hostID())
    }

    private func signIn() async {
        working = true
        message = L("settings.chatgpt.waiting")
        defer { working = false }
        do {
            let signedIn = try await auth().signIn(previous: account, page: L("settings.chatgpt.browserPage")) { url in
                Task { @MainActor in NSWorkspace.shared.open(url) }
            }
            try credentials.setChatGPTAccount(signedIn)
            account = signedIn
            message = nil
            model.refreshAccounts()
        } catch {
            message = error.localizedDescription
        }
    }

    private func signOut() async {
        guard let account else { return }
        working = true
        defer { working = false }
        let store = credentials
        let session = ChatGPTSession(account: account, auth: (try? auth()) ?? ChatGPTAuth(appName: "Lectern", hostID: account.hostID)) { updated in
            try? store.setChatGPTAccount(updated)
        }
        let confirmed = await session.signOut()
        self.account = await session.account
        message = confirmed ? nil : L("settings.signOutUnconfirmed")
        model.refreshAccounts()
    }
}

private struct KeyRow: View {
    @Environment(AppModel.self) private var model
    let kind: ProviderKind
    let title: String
    let hint: String
    let link: URL
    let credentials: Credentials
    @State private var key = ""
    @State private var saved = false
    @State private var checking = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(message ?? (saved ? L("settings.connectedPlain") : L("settings.notConnected")))
                    .font(.system(size: 12))
                    .foregroundStyle(saved && message == nil ? Color(hex: 0x047857) : Theme.tertiary)
            }
            HStack(spacing: 8) {
                SecureField(hint, text: $key)
                    .textFieldStyle(.roundedBorder)
                Button(saved && key.isEmpty ? L("settings.remove") : L("settings.save")) { Task { await save() } }
                    .disabled(checking || (!saved && key.isEmpty))
                Link(L("settings.getKey"), destination: link)
            }
        }
        .task { saved = (try? credentials.apiKey(for: kind)) != nil }
    }

    /// Checks the key by listing models before keeping it.
    private func save() async {
        if saved && key.isEmpty {
            try? credentials.setAPIKey(nil, for: kind)
            saved = false
            model.refreshAccounts()
            return
        }
        checking = true
        defer { checking = false }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider: any LanguageModelProvider
        switch kind {
        case .gemini: provider = GeminiProvider(apiKey: trimmed)
        case .anthropic: provider = AnthropicProvider(apiKey: trimmed)
        default: provider = OpenAIProvider(credential: .apiKey(trimmed))
        }
        do {
            _ = try await provider.models()
            try credentials.setAPIKey(trimmed, for: kind)
            saved = true
            key = ""
            message = nil
            model.refreshAccounts()
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct EndpointRow: View {
    @Environment(AppModel.self) private var model
    let credentials: Credentials
    @AppStorage("endpoint.url") private var address = ""
    @State private var key = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("settings.endpoint")).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(Theme.tertiary) }
            }
            HStack(spacing: 8) {
                TextField("http://127.0.0.1:8317/v1", text: $address)
                    .textFieldStyle(.roundedBorder)
                SecureField(L("settings.endpoint.key"), text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                Button(L("settings.check")) { Task { await check() } }
                    .disabled(URL(string: address)?.host == nil)
            }
        }
    }

    private func check() async {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)) else { return }
        let stored = (try? credentials.endpointKey("default")) ?? nil
        let provider = OpenAICompatibleProvider(baseURL: url, apiKey: key.isEmpty ? stored : key)
        do {
            let models = try await provider.models()
            if !key.isEmpty { try? credentials.setEndpointKey(key, for: "default") }
            key = ""
            message = L("settings.endpoint.found", models.count)
            model.refreshAccounts()
        } catch {
            message = error.localizedDescription
        }
    }
}

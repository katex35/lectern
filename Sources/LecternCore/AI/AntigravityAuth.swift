import Foundation
import Security

/// A Google account linked the way the Antigravity editor links one: Google's OAuth flow with the
/// Antigravity client, answered at `localhost:51121`, and a Cloud Code project for the account.
/// Gemini then transcribes on the account's own quota, without an AI Studio key.
public struct AntigravityAccount: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var email: String
    /// The `cloudaicompanionProject` Cloud Code gave the account; found at sign-in, or on the first request.
    public var projectID: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, email: String, projectID: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.email = email
        self.projectID = projectID
    }
}

/// The browser sign-in, project discovery and token renewal with the Antigravity OAuth client.
public struct AntigravityAuth: Sendable {
    public struct Endpoints: Sendable {
        public var authorize: URL
        public var token: URL
        public var userInfo: URL
        /// `loadCodeAssist`, `onboardUser` and the model requests go to the daily endpoint.
        public var api: URL

        public static let google = Endpoints(
            authorize: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            token: URL(string: "https://oauth2.googleapis.com/token")!,
            userInfo: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo?alt=json")!,
            api: URL(string: "https://daily-cloudcode-pa.googleapis.com")!)

        public init(authorize: URL, token: URL, userInfo: URL, api: URL) {
            self.authorize = authorize
            self.token = token
            self.userInfo = userInfo
            self.api = api
        }
    }

    public static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let clientSecret = "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"
    public static let callbackPort: UInt16 = 51121
    static let callbackPath = "/oauth-callback"
    static let scopes = ["https://www.googleapis.com/auth/cloud-platform", "https://www.googleapis.com/auth/userinfo.email",
                         "https://www.googleapis.com/auth/userinfo.profile", "https://www.googleapis.com/auth/cclog",
                         "https://www.googleapis.com/auth/experimentsandconfigs"]
    static let apiVersion = "v1internal"
    /// Tokens are renewed this long before they expire.
    static let refreshLead: TimeInterval = 5 * 60
    static let onboardAttempts = 5

    var endpoints: Endpoints
    var callbackPort: UInt16
    let http: HTTPClient
    let version: AntigravityVersion

    public init(endpoints: Endpoints = .google, callbackPort: UInt16 = AntigravityAuth.callbackPort, session: URLSession = .shared,
                version: AntigravityVersion = .shared) {
        self.endpoints = endpoints
        self.callbackPort = callbackPort
        self.http = HTTPClient(session: session)
        self.version = version
    }

    var redirectURI: String { "http://localhost:\(callbackPort)\(Self.callbackPath)" }

    // MARK: - sign-in

    public func signIn(timeout: TimeInterval = 300,
                       page: String = "<!doctype html><meta charset=utf-8><title>Lectern</title><p>You can close this tab.</p>",
                       open: @Sendable (URL) -> Void) async throws -> AntigravityAccount {
        let state = CodexAuth.randomState()
        let server = try await LoopbackServer.start(path: Self.callbackPath, state: state, page: page, port: callbackPort)
        defer { server.stop() }
        open(authorizeURL(state: state))
        let callback = try await server.callback(timeout: timeout)

        if let error = callback["error"], !error.isEmpty {
            if error == "access_denied" { throw ChatGPTAuthError.cancelled }
            throw ChatGPTAuthError.failed(callback["error_description"] ?? error)
        }
        guard callback["state"] == state else { throw ChatGPTAuthError.stateMismatch }
        guard let code = callback["code"], !code.isEmpty else { throw ChatGPTAuthError.failed("No authorization code came back") }

        let tokens = try await exchange(code: code)
        let email = try await userEmail(accessToken: tokens.access_token)
        let project = try await projectID(accessToken: tokens.access_token)
        return AntigravityAccount(accessToken: tokens.access_token, refreshToken: tokens.refresh_token ?? "",
                                  expiresAt: Date().addingTimeInterval(tokens.expires_in ?? 0), email: email, projectID: project)
    }

    func authorizeURL(state: String) -> URL {
        let items: [(String, String)] = [
            ("access_type", "offline"), ("client_id", Self.clientID), ("prompt", "consent"), ("redirect_uri", redirectURI),
            ("response_type", "code"), ("scope", Self.scopes.joined(separator: " ")), ("state", state),
        ]
        var components = URLComponents(url: endpoints.authorize, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = items.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        return components.url!
    }

    // MARK: - tokens

    struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double?
    }

    func exchange(code: String) async throws -> TokenResponse {
        var request = URLRequest(url: endpoints.token)
        request.setForm([("code", code), ("client_id", Self.clientID), ("client_secret", Self.clientSecret),
                         ("redirect_uri", redirectURI), ("grant_type", "authorization_code")])
        return try await http.json(TokenResponse.self, request, errors: Self.oauthError)
    }

    func refresh(_ account: AntigravityAccount) async throws -> AntigravityAccount {
        guard !account.refreshToken.isEmpty else { throw ProviderError.unauthorized("No refresh token") }
        var request = URLRequest(url: endpoints.token)
        request.setForm([("client_id", Self.clientID), ("client_secret", Self.clientSecret), ("grant_type", "refresh_token"),
                         ("refresh_token", account.refreshToken)])
        // the real Antigravity renews with Go's default User-Agent
        request.setValue("Go-http-client/2.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let response = try await http.json(TokenResponse.self, request, errors: Self.oauthError)
        var renewed = account
        renewed.accessToken = response.access_token
        if let refresh = response.refresh_token, !refresh.isEmpty { renewed.refreshToken = refresh }
        renewed.expiresAt = Date().addingTimeInterval(response.expires_in ?? 0)
        if renewed.projectID == nil || renewed.projectID?.isEmpty == true {
            renewed.projectID = try? await projectID(accessToken: renewed.accessToken)
        }
        return renewed
    }

    static let oauthError: ErrorMapper = { status, body, response in
        let message = HTTPErrors.message(body)
        if HTTPErrors.code(body) == "invalid_grant" { return .unauthorized(message) }
        return HTTPErrors.byStatus(status, message, retryAfter: HTTPErrors.retryAfter(response))
    }

    // MARK: - account

    struct UserInfo: Decodable {
        var email: String?
    }

    func userEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: endpoints.userInfo)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(await version.userAgent(), forHTTPHeaderField: "User-Agent")
        let info = try await http.json(UserInfo.self, request, errors: Self.apiError)
        guard let email = info.email?.trimmingCharacters(in: .whitespaces), !email.isEmpty else {
            throw ChatGPTAuthError.failed("The account's email was not returned")
        }
        return email
    }

    /// The account's Cloud Code project from `loadCodeAssist`; an account without one is onboarded
    /// to its default tier first.
    func projectID(accessToken: String) async throws -> String {
        let userAgent = await version.userAgent()
        var request = URLRequest(url: endpoints.api.appendingPathComponent("\(Self.apiVersion):loadCodeAssist"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        try request.setJSON(["metadata": ["ideType": "ANTIGRAVITY"]])
        request.timeoutInterval = 30
        let loaded = HTTPErrors.object(try await http.data(request, errors: Self.apiError)) ?? [:]
        if let project = Self.project(in: loaded) { return project }
        let project = try await onboard(accessToken: accessToken, tier: Self.defaultTier(loaded))
        guard !project.isEmpty else { throw ChatGPTAuthError.failed("Cloud Code gave the account no project") }
        return project
    }

    /// `cloudaicompanionProject`, `projectId` or `project`, as text or as `{id}`.
    static func project(in object: [String: Any]) -> String? {
        for key in ["cloudaicompanionProject", "projectId", "project"] {
            if let text = object[key] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text.trimmingCharacters(in: .whitespaces)
            }
            if let nested = object[key] as? [String: Any], let id = nested["id"] as? String,
               !id.trimmingCharacters(in: .whitespaces).isEmpty {
                return id.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The default of `allowedTiers`, else the current tier, else `free-tier`.
    static func defaultTier(_ loaded: [String: Any]) -> String {
        for tier in loaded["allowedTiers"] as? [[String: Any]] ?? [] where tier["isDefault"] as? Bool == true {
            if let id = tier["id"] as? String, !id.trimmingCharacters(in: .whitespaces).isEmpty { return id.trimmingCharacters(in: .whitespaces) }
        }
        if let current = loaded["currentTier"] as? [String: Any], let id = current["id"] as? String,
           !id.trimmingCharacters(in: .whitespaces).isEmpty {
            return id.trimmingCharacters(in: .whitespaces)
        }
        return "free-tier"
    }

    /// `onboardUser` is a long-running operation: asked again every two seconds until it is done.
    func onboard(accessToken: String, tier: String) async throws -> String {
        let userAgent = await version.onboardUserAgent()
        let body: [String: Any] = ["tier_id": tier, "metadata": ["ide_type": "ANTIGRAVITY", "ide_version": await version.current(),
                                                                "ide_name": "antigravity"]]
        for attempt in 1...Self.onboardAttempts {
            var request = URLRequest(url: endpoints.api.appendingPathComponent("\(Self.apiVersion):onboardUser"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(AntigravityVersion.googAPIClient, forHTTPHeaderField: "X-Goog-Api-Client")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.timeoutInterval = 30
            let data = try await http.data(request, errors: Self.apiError)
            let object = HTTPErrors.object(data) ?? [:]
            if object["done"] as? Bool == true {
                guard let response = object["response"] as? [String: Any], let project = Self.project(in: response) else {
                    throw ChatGPTAuthError.failed("Onboarding finished without a project")
                }
                return project
            }
            if attempt < Self.onboardAttempts { try await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        throw ChatGPTAuthError.failed("Onboarding did not finish after \(Self.onboardAttempts) attempts")
    }

    static let apiError: ErrorMapper = { status, body, response in
        GeminiProvider.map(body, status: status, retryAfter: HTTPErrors.retryAfter(response))
    }
}

/// The Antigravity editor's version, which Cloud Code checks: the latest from its update manifest,
/// fetched at most every six hours, else the known good one.
public actor AntigravityVersion {
    public static let shared = AntigravityVersion()
    /// Cloud Code refuses the newer models to clients below 2.23.0.
    static let fallback = "2.24.0"
    static let platform = "aidev_client; os_type=darwin; arch=arm64"
    static let nodeAPIClient = "google-api-nodejs-client/10.3.0"
    static let googAPIClient = "gl-node/22.21.1"
    static let changelists = ["2.23.0": "998057262", "2.24.0": "1000335682"]
    static let manifest = URL(string: "https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/latest-arm64-mac.yml")!
    static let cacheLife: TimeInterval = 6 * 3600

    private var cached = AntigravityVersion.fallback
    private var expires = Date.distantPast
    private var fetching: Task<String, Never>?
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    func current() async -> String {
        if Date() < expires { return cached }
        if let fetching { return await fetching.value }
        let task = Task { () -> String in
            if let fetched = await Self.fetch(session: session) { cached = fetched }
            expires = Date().addingTimeInterval(Self.cacheLife)
            return cached
        }
        fetching = task
        defer { fetching = nil }
        return await task.value
    }

    /// `version: x.y.z` of the manifest.
    static func fetch(session: URLSession) async -> String? {
        var request = URLRequest(url: manifest)
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("version:") else { continue }
            let value = trimmed.dropFirst("version:".count).trimmingCharacters(in: CharacterSet.whitespaces.union(["'", "\""]))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// `antigravity/hub/<version> (aidev_client; os_type=darwin; arch=arm64; cl=<changelist>)`.
    func userAgent() async -> String {
        let version = await current()
        var metadata = Self.platform
        if let changelist = Self.changelists[version] { metadata += "; cl=\(changelist)" }
        return "antigravity/hub/\(version) (\(metadata))"
    }

    /// The long control-plane form, used by `onboardUser`.
    func onboardUserAgent() async -> String {
        await userAgent() + " " + Self.nodeAPIClient
    }
}

/// Keeps a linked account's access token and project fresh; refreshes run one at a time.
public actor AntigravitySession {
    public private(set) var account: AntigravityAccount?
    let auth: AntigravityAuth
    let save: @Sendable (AntigravityAccount?) -> Void
    private var refreshing: Task<AntigravityAccount, Error>?

    public init(account: AntigravityAccount, auth: AntigravityAuth, save: @escaping @Sendable (AntigravityAccount?) -> Void) {
        self.account = account
        self.auth = auth
        self.save = save
    }

    /// A token good for at least five more minutes, and the project to send with it.
    public func credentials() async throws -> (accessToken: String, projectID: String) {
        guard var account else { throw ProviderError.notConnected }
        if account.expiresAt.timeIntervalSinceNow <= AntigravityAuth.refreshLead { account = try await refresh() }
        if let project = account.projectID, !project.isEmpty { return (account.accessToken, project) }
        let project = try await auth.projectID(accessToken: account.accessToken)
        if self.account?.accessToken == account.accessToken {
            self.account?.projectID = project
            if let current = self.account { save(current) }
        }
        return (account.accessToken, project)
    }

    /// Renews the tokens once for every caller waiting at the same time; the renewal and the storing
    /// of its result are one task, so a joining caller sees the stored result, or nothing after a sign-out.
    @discardableResult
    public func refresh() async throws -> AntigravityAccount {
        if let refreshing { return try await refreshing.value }
        guard let account else { throw ProviderError.notConnected }
        let task = Task { try await self.renew(account) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func renew(_ account: AntigravityAccount) async throws -> AntigravityAccount {
        let renewing = account.refreshToken
        do {
            let renewed = try await auth.refresh(account)
            guard self.account?.refreshToken == renewing else {
                if let current = self.account { return current }
                throw ProviderError.notConnected
            }
            self.account = renewed
            save(renewed)
            return renewed
        } catch ProviderError.unauthorized(let message) {
            if self.account?.refreshToken == renewing {
                self.account = nil
                save(nil)
            } else if let current = self.account {
                return current
            }
            throw ProviderError.unauthorized(message)
        }
    }

    public func signOut() {
        account = nil
        save(nil)
    }
}

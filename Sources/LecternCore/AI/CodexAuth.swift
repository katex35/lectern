import CryptoKit
import Foundation
import Security

/// A ChatGPT account linked the way the Codex CLI links one: OpenAI's OAuth flow with the Codex
/// client, answered at `localhost:1455`. The tokens are the ones ChatGPT's own Codex backend takes,
/// which writes notes and draws covers on the user's plan.
public struct CodexAccount: Codable, Hashable, Sendable {
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    /// The ChatGPT account (`chatgpt_account_id` of the ID token), sent with every request.
    public var accountID: String
    public var email: String?
    /// `free`, `plus`, `pro`, `team`...
    public var planType: String
    public var expiresAt: Date
    public var lastRefresh: Date

    public init(idToken: String, accessToken: String, refreshToken: String, accountID: String, email: String?,
                planType: String, expiresAt: Date, lastRefresh: Date) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.email = email
        self.planType = planType
        self.expiresAt = expiresAt
        self.lastRefresh = lastRefresh
    }
}

/// The browser sign-in and token renewal with the Codex OAuth client.
public struct CodexAuth: Sendable {
    public struct Endpoints: Sendable {
        public var authorize: URL
        public var token: URL

        public static let openAI = Endpoints(authorize: URL(string: "https://auth.openai.com/oauth/authorize")!,
                                             token: URL(string: "https://auth.openai.com/oauth/token")!)

        public init(authorize: URL, token: URL) {
            self.authorize = authorize
            self.token = token
        }
    }

    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// Where the tokens are spent: ChatGPT's Codex backend, which speaks the Responses API.
    public static let backend = URL(string: "https://chatgpt.com/backend-api/codex")!
    /// The backend serves the Codex CLI; requests introduce themselves as it.
    static let userAgent = "codex-tui/0.154.0 (Mac OS 26.5.2; arm64) iTerm.app/3.6.11 (codex-tui; 0.154.0)"
    static let originator = "codex-tui"
    /// Registered with the client: the sign-in has to be answered on this port.
    public static let callbackPort: UInt16 = 1455
    static let callbackPath = "/auth/callback"
    static let scope = "openid email profile offline_access"
    static let refreshScope = "openid profile email"
    public static let defaultPlanType = "free"
    /// Tokens are renewed this long before they expire, as the Codex CLI does.
    static let refreshLead: TimeInterval = 96 * 3600
    static let refreshAttempts = 3

    var endpoints: Endpoints
    var callbackPort: UInt16
    let http: HTTPClient

    public init(endpoints: Endpoints = .openAI, callbackPort: UInt16 = CodexAuth.callbackPort, session: URLSession = .shared) {
        self.endpoints = endpoints
        self.callbackPort = callbackPort
        self.http = HTTPClient(session: session)
    }

    var redirectURI: String { "http://localhost:\(callbackPort)\(Self.callbackPath)" }

    /// The headers every request to the backend carries.
    static func apply(to request: inout URLRequest, token: String, accountID: String?) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
        request.setValue(originator, forHTTPHeaderField: "Originator")
        if let accountID, !accountID.isEmpty { request.setValue(accountID, forHTTPHeaderField: "Chatgpt-Account-Id") }
    }

    // MARK: - sign-in

    /// Signs in through the user's browser; `open` shows the URL, `page` is what the browser shows afterwards.
    public func signIn(timeout: TimeInterval = 300,
                       page: String = "<!doctype html><meta charset=utf-8><title>Lectern</title><p>You can close this tab.</p>",
                       open: @Sendable (URL) -> Void) async throws -> CodexAccount {
        let state = Self.randomState()
        let verifier = Self.codeVerifier()
        let server = try await LoopbackServer.start(path: Self.callbackPath, state: state, page: page, port: callbackPort)
        defer { server.stop() }
        open(authorizeURL(state: state, challenge: Self.challenge(for: verifier)))
        let callback = try await server.callback(timeout: timeout)

        if let error = callback["error"], !error.isEmpty {
            if error == "access_denied" { throw ChatGPTAuthError.cancelled }
            throw ChatGPTAuthError.failed(callback["error_description"] ?? error)
        }
        guard let code = callback["code"], !code.isEmpty else { throw ChatGPTAuthError.failed("No authorization code came back") }
        guard callback["state"] == state else { throw ChatGPTAuthError.stateMismatch }
        return try await exchange(code: code, verifier: verifier)
    }

    func authorizeURL(state: String, challenge: String) -> URL {
        let items: [(String, String)] = [
            ("client_id", Self.clientID), ("response_type", "code"), ("redirect_uri", redirectURI), ("scope", Self.scope),
            ("state", state), ("code_challenge", challenge), ("code_challenge_method", "S256"), ("prompt", "login"),
            ("id_token_add_organizations", "true"), ("codex_cli_simplified_flow", "true"),
        ]
        var components = URLComponents(url: endpoints.authorize, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = items.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        return components.url!
    }

    /// 16 random bytes as hex.
    static func randomState() -> String {
        randomBytes(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 96 random bytes as base64url: a 128-character verifier.
    static func codeVerifier() -> String {
        Base64URL.encode(randomBytes(96))
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no system randomness")
        return Data(bytes)
    }

    static func challenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    // MARK: - tokens

    struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var id_token: String?
        var expires_in: Double?
    }

    func exchange(code: String, verifier: String) async throws -> CodexAccount {
        var request = URLRequest(url: endpoints.token)
        request.setForm([("grant_type", "authorization_code"), ("client_id", Self.clientID), ("code", code),
                         ("redirect_uri", redirectURI), ("code_verifier", verifier)])
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await http.json(TokenResponse.self, request, errors: Self.oauthError)
        return try Self.account(from: response, keeping: nil)
    }

    /// Renews the token set. Only a refresh token already used once ends the sign-in; anything else is tried again.
    func refresh(_ account: CodexAccount) async throws -> CodexAccount {
        var last: Error = ProviderError.unavailable("Token refresh failed")
        for attempt in 0..<Self.refreshAttempts {
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000) }
            var request = URLRequest(url: endpoints.token)
            request.setForm([("client_id", Self.clientID), ("grant_type", "refresh_token"),
                             ("refresh_token", account.refreshToken), ("scope", Self.refreshScope)])
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30
            do {
                let response = try await http.json(TokenResponse.self, request, errors: Self.oauthError)
                return try Self.account(from: response, keeping: account)
            } catch ProviderError.unauthorized(let message) {
                throw ProviderError.unauthorized(message)
            } catch {
                last = error
            }
        }
        throw last
    }

    static func account(from response: TokenResponse, keeping old: CodexAccount?) throws -> CodexAccount {
        guard let refresh = response.refresh_token ?? old?.refreshToken else {
            throw ChatGPTAuthError.failed("No refresh token came back")
        }
        let idToken = response.id_token ?? old?.idToken ?? ""
        let claims = Self.claims(of: idToken)
        let now = Date()
        return CodexAccount(idToken: idToken, accessToken: response.access_token, refreshToken: refresh,
                            accountID: claims?.accountID ?? old?.accountID ?? "",
                            email: claims?.email ?? old?.email,
                            planType: claims?.planType ?? old?.planType ?? Self.defaultPlanType,
                            expiresAt: now.addingTimeInterval(response.expires_in ?? 0), lastRefresh: now)
    }

    /// `refresh_token_reused` cannot be retried; a rejected grant ends the sign-in too. Everything
    /// else (a 5xx, a proxy page) is temporary.
    static let oauthError: ErrorMapper = { status, body, response in
        let code = HTTPErrors.code(body)
        let message = HTTPErrors.message(body)
        let text = String(decoding: body, as: UTF8.self).lowercased()
        if code == "refresh_token_reused" || text.contains("refresh_token_reused") || code == "invalid_grant" {
            return .unauthorized(message)
        }
        switch HTTPErrors.byStatus(status, message, retryAfter: HTTPErrors.retryAfter(response)) {
        case .unauthorized, .forbidden, .invalidRequest, .usageLimit: return .unavailable("Token refresh failed with status \(status): \(message)")
        case let other: return other
        }
    }

    // MARK: - ID token

    /// What the ID token says about the account. The token comes straight from OpenAI over TLS, so
    /// its claims are read without checking the signature, as the Codex CLI does.
    struct Claims: Decodable, Equatable {
        struct AuthInfo: Decodable, Equatable {
            var chatgpt_account_id: String?
            var chatgpt_plan_type: String?
        }

        var email: String?
        var auth: AuthInfo?

        enum CodingKeys: String, CodingKey {
            case email
            case auth = "https://api.openai.com/auth"
        }

        var accountID: String? { auth?.chatgpt_account_id.flatMap { $0.isEmpty ? nil : $0 } }
        var planType: String? {
            guard let plan = auth?.chatgpt_plan_type?.trimmingCharacters(in: .whitespaces), !plan.isEmpty else { return nil }
            return plan
        }
    }

    static func claims(of idToken: String) -> Claims? {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = Base64URL.decode(parts[1]) else { return nil }
        return try? JSONDecoder().decode(Claims.self, from: payload)
    }
}

/// Keeps a linked account's access token fresh; refreshes run one at a time.
public actor CodexSession {
    public private(set) var account: CodexAccount?
    let auth: CodexAuth
    let save: @Sendable (CodexAccount?) -> Void
    private var refreshing: Task<CodexAccount, Error>?

    /// `save` is called with every change so the account can be written to the keychain; nil means signed out.
    public init(account: CodexAccount, auth: CodexAuth, save: @escaping @Sendable (CodexAccount?) -> Void) {
        self.account = account
        self.auth = auth
        self.save = save
    }

    /// The access token, renewed when it is within four days of expiry.
    public func accessToken() async throws -> String {
        guard let account else { throw ProviderError.notConnected }
        if account.expiresAt.timeIntervalSinceNow > CodexAuth.refreshLead { return account.accessToken }
        return try await refresh().accessToken
    }

    public func accountID() -> String? { account?.accountID }

    /// Renews the tokens once for every caller waiting at the same time; the renewal and the storing
    /// of its result are one task, so a joining caller sees the stored result, or nothing after a sign-out.
    @discardableResult
    public func refresh() async throws -> CodexAccount {
        if let refreshing { return try await refreshing.value }
        guard let account else { throw ProviderError.notConnected }
        let task = Task { try await self.renew(account) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func renew(_ account: CodexAccount) async throws -> CodexAccount {
        // the actor can sign out meanwhile: a result only applies to the token set it renewed
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

    /// Forgets the tokens. OpenAI's Codex client has no revocation endpoint; the user can remove the
    /// device in ChatGPT's settings.
    public func signOut() {
        account = nil
        save(nil)
    }
}

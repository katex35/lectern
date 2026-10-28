import CryptoKit
import Foundation
import Security

/// A ChatGPT account linked with "Sign in with ChatGPT" for open-source apps: answers count against
/// the user's ChatGPT plan, and Lectern never sees a password.
/// https://developers.openai.com/siwc/token-sharing-open-source
public struct ChatGPTAccount: Codable, Hashable, Sendable {
    /// Issued at the first sign-in (`oaiapp_...`); kept after sign-out and reused for the next one.
    public var clientID: String
    public var hostID: String
    /// The account's identity (`sub` of the ID token).
    public var subject: String
    public var email: String?
    /// Nil after signing out.
    public var tokens: ChatGPTTokens?

    public init(clientID: String, hostID: String, subject: String, email: String? = nil, tokens: ChatGPTTokens? = nil) {
        self.clientID = clientID
        self.hostID = hostID
        self.subject = subject
        self.email = email
        self.tokens = tokens
    }

    /// The user allowed answers on their plan. Without it the account stays linked but cannot be used.
    public var canUsePlan: Bool { tokens?.scopes.contains(ChatGPTAuth.planScope) == true }
}

public struct ChatGPTTokens: Codable, Hashable, Sendable {
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scopes: [String]
    public var earliestRefreshAt: Date?

    public init(idToken: String, accessToken: String, refreshToken: String, expiresAt: Date, scopes: [String],
                earliestRefreshAt: Date? = nil) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.earliestRefreshAt = earliestRefreshAt
    }
}

public enum ChatGPTAuthError: Error, Equatable, LocalizedError {
    /// The user declined in the browser.
    case cancelled
    case timedOut
    /// The browser came back with someone else's request.
    case stateMismatch
    /// A different ChatGPT account signed in than the one being renewed.
    case differentAccount
    case invalidIDToken(String)
    /// The sign-in's registered callback port is taken by another program.
    case portInUse(Int)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled"
        case .timedOut: return "Sign-in timed out"
        case .stateMismatch: return "The sign-in answer did not match this request"
        case .differentAccount: return "A different ChatGPT account signed in"
        case .invalidIDToken(let reason): return "The sign-in could not be verified: \(reason)"
        case .portInUse(let port): return "Port \(port) is in use by another program; close it and sign in again"
        case .failed(let reason): return reason
        }
    }
}

/// The browser sign-in, token renewal and revocation.
public struct ChatGPTAuth: Sendable {
    public struct Endpoints: Sendable {
        public var authorize: URL
        public var token: URL
        public var discovery: URL

        public static let openAI = Endpoints(
            authorize: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
            token: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!,
            discovery: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)

        public init(authorize: URL, token: URL, discovery: URL) {
            self.authorize = authorize
            self.token = token
            self.discovery = discovery
        }
    }

    public static let issuer = "https://auth.openai.com"
    static let registrationClient = "dynamic_agent_client"
    static let resource = "https://api.openai.com/v1"
    static let planScope = "chatgpt.tokens.use.direct"
    static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let callbackPath = "/auth/callback"
    /// Tokens closer than this to expiry are renewed before use.
    static let refreshMargin: TimeInterval = 300

    /// Shown to the user as the app asking for access.
    public var appName: String
    /// Stable for this Mac (`ext_agent_host_id`).
    public var hostID: String
    var endpoints: Endpoints
    let http: HTTPClient
    let metadata: OpenIDMetadata

    public init(appName: String, hostID: String, endpoints: Endpoints = .openAI, session: URLSession = .shared) {
        self.appName = appName
        self.hostID = hostID
        self.endpoints = endpoints
        self.http = HTTPClient(session: session)
        self.metadata = OpenIDMetadata(discovery: endpoints.discovery, http: http)
    }

    // MARK: - sign-in

    /// Signs in through the user's browser. `previous` is the account being renewed, or nil to link a
    /// new one; `open` shows the URL in the browser. `page` is what the browser shows afterwards.
    public func signIn(previous: ChatGPTAccount? = nil, timeout: TimeInterval = 300,
                       page: String = "<!doctype html><meta charset=utf-8><title>Lectern</title><p>You can close this tab.</p>",
                       open: @Sendable (URL) -> Void) async throws -> ChatGPTAccount {
        let state = Self.randomToken()
        let server = try await LoopbackServer.start(path: Self.callbackPath, state: state, page: page)
        defer { server.stop() }
        let redirect = "http://127.0.0.1:\(server.port)\(Self.callbackPath)"
        let nonce = Self.randomToken()
        let verifier = Self.randomToken()
        open(authorizeURL(previous: previous, redirect: redirect, state: state, nonce: nonce,
                          challenge: Self.challenge(for: verifier)))
        let callback = try await server.callback(timeout: timeout)

        guard callback["state"] == state else { throw ChatGPTAuthError.stateMismatch }
        if let error = callback["error"] {
            if error == "access_denied" { throw ChatGPTAuthError.cancelled }
            throw ChatGPTAuthError.failed(callback["error_description"] ?? error)
        }
        guard let code = callback["code"], !code.isEmpty else { throw ChatGPTAuthError.failed("No authorization code came back") }
        let clientID: String
        if let previous {
            if let returned = callback["client_id"], returned != previous.clientID { throw ChatGPTAuthError.differentAccount }
            clientID = previous.clientID
        } else {
            guard let issued = callback["client_id"], !issued.isEmpty, issued != Self.registrationClient else {
                throw ChatGPTAuthError.failed("No client id was issued")
            }
            clientID = issued
        }

        var request = URLRequest(url: endpoints.token)
        request.setForm([("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
                         ("code_verifier", verifier), ("redirect_uri", redirect), ("resource", Self.resource)])
        let response = try await http.json(TokenResponse.self, request, errors: Self.oauthError)
        guard let idToken = response.id_token else { throw ChatGPTAuthError.invalidIDToken("missing") }
        let identity = try await validate(idToken: idToken, clientID: clientID, nonce: nonce)
        if let previous, previous.subject != identity.subject { throw ChatGPTAuthError.differentAccount }
        return ChatGPTAccount(clientID: clientID, hostID: hostID, subject: identity.subject,
                              email: identity.email ?? previous?.email, tokens: try response.tokens(keeping: nil))
    }

    func authorizeURL(previous: ChatGPTAccount?, redirect: String, state: String, nonce: String, challenge: String) -> URL {
        var items: [(String, String)] = [("client_id", previous?.clientID ?? Self.registrationClient)]
        if previous == nil { items.append(("agent_name_hint", appName)) }
        items.append(("ext_agent_host_id", hostID))
        if let hint = previous?.tokens?.idToken { items.append(("id_token_hint", hint)) }
        if let email = previous?.email { items.append(("login_hint", email)) }
        items += [("response_type", "code"), ("redirect_uri", redirect), ("scope", Self.scope), ("resource", Self.resource),
                  ("state", state), ("nonce", nonce), ("code_challenge_method", "S256"), ("code_challenge", challenge)]
        var components = URLComponents(url: endpoints.authorize, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = items.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        return components.url!
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no system randomness")
        return Base64URL.encode(Data(bytes))
    }

    /// PKCE S256: base64url of the verifier's SHA-256, without padding.
    static func challenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    // MARK: - tokens

    struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var id_token: String?
        var expires_in: Double?
        var scope: String?
        var earliest_refresh_at: FlexibleDate?

        func tokens(keeping old: ChatGPTTokens?) throws -> ChatGPTTokens {
            guard let refresh = refresh_token ?? old?.refreshToken else {
                throw ChatGPTAuthError.failed("No refresh token came back")
            }
            guard let id = id_token ?? old?.idToken else { throw ChatGPTAuthError.invalidIDToken("missing") }
            let scopes = scope.map { $0.split(separator: " ").map(String.init) } ?? old?.scopes ?? []
            return ChatGPTTokens(idToken: id, accessToken: access_token, refreshToken: refresh,
                                 expiresAt: Date().addingTimeInterval(expires_in ?? 3600), scopes: scopes,
                                 earliestRefreshAt: earliest_refresh_at?.date)
        }
    }

    /// A time given either as Unix seconds or as ISO 8601 text.
    struct FlexibleDate: Decodable {
        var date: Date?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                date = Date(timeIntervalSince1970: seconds)
            } else if let text = try? container.decode(String.self) {
                date = ISO8601DateFormatter().date(from: text)
            }
        }
    }

    /// Renews the token set; refresh tokens rotate, so the returned set replaces the old one whole.
    func refresh(_ account: ChatGPTAccount) async throws -> ChatGPTTokens {
        guard let old = account.tokens else { throw ProviderError.notConnected }
        var request = URLRequest(url: endpoints.token)
        // no `scope`: the existing grant is kept
        request.setForm([("grant_type", "refresh_token"), ("client_id", account.clientID),
                         ("refresh_token", old.refreshToken), ("resource", Self.resource)])
        let response = try await http.json(TokenResponse.self, request, errors: Self.oauthError)
        if let idToken = response.id_token {
            let identity = try await validate(idToken: idToken, clientID: account.clientID, nonce: nil)
            guard identity.subject == account.subject else { throw ChatGPTAuthError.differentAccount }
        }
        return try response.tokens(keeping: old)
    }

    /// Revokes the refresh token at OpenAI. False when that could not be confirmed; the user can
    /// still disconnect Lectern in ChatGPT's settings.
    func revoke(_ account: ChatGPTAccount) async -> Bool {
        guard let tokens = account.tokens else { return true }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000) }
            do {
                guard let endpoint = try await metadata.document().revocation_endpoint.flatMap({ URL(string: $0) }) else {
                    return false
                }
                var request = URLRequest(url: endpoint)
                request.setForm([("token", tokens.refreshToken), ("token_type_hint", "refresh_token"),
                                 ("client_id", account.clientID)])
                _ = try await http.data(request, errors: Self.oauthError)
                return true
            } catch let error as ProviderError where error.isTemporary {
                continue
            } catch {
                return false
            }
        }
        return false
    }

    static let terminalRefreshErrors: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired",
                                                     "refresh_token_expired", "refresh_token_invalidated",
                                                     "refresh_token_reused"]

    /// Only the terminal refresh errors become `.unauthorized`, which ends the sign-in. Any other
    /// rejection (a proxy's 401 page, an unknown code) keeps the saved sign-in, and network and
    /// server trouble stays temporary.
    static let oauthError: ErrorMapper = { status, body, response in
        let code = HTTPErrors.code(body)
        let message = HTTPErrors.message(body)
        if let code, terminalRefreshErrors.contains(code) { return .unauthorized(message) }
        if code == "invalid_client" { return .forbidden(message) }
        switch HTTPErrors.byStatus(status, message, retryAfter: HTTPErrors.retryAfter(response)) {
        case .unauthorized, .forbidden: return .invalidRequest(message)
        case let other: return other
        }
    }

    // MARK: - ID token

    struct Identity: Equatable {
        var subject: String
        var email: String?
    }

    struct JWTHeader: Decodable {
        var alg: String
        var kid: String?
    }

    struct Claims: Decodable {
        var iss: String
        var aud: Audience
        var exp: Double
        var sub: String
        var nonce: String?
        var email: String?
    }

    /// `aud` is a string or a list of strings.
    struct Audience: Decodable {
        var values: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let one = try? container.decode(String.self) {
                values = [one]
            } else {
                values = try container.decode([String].self)
            }
        }
    }

    /// Checks the signature against OpenAI's published keys, then issuer, audience, expiry and nonce.
    func validate(idToken: String, clientID: String, nonce: String?) async throws -> Identity {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = Base64URL.decode(parts[0]), let payload = Base64URL.decode(parts[1]),
              let signature = Base64URL.decode(parts[2]) else { throw ChatGPTAuthError.invalidIDToken("malformed") }
        guard let header = try? JSONDecoder().decode(JWTHeader.self, from: headerData), header.alg == "RS256" else {
            throw ChatGPTAuthError.invalidIDToken("unsupported signature")
        }
        let key = try await metadata.key(id: header.kid)
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil) else {
            throw ChatGPTAuthError.invalidIDToken("bad signature")
        }
        guard let claims = try? JSONDecoder().decode(Claims.self, from: payload) else {
            throw ChatGPTAuthError.invalidIDToken("unreadable claims")
        }
        guard claims.iss == Self.issuer else { throw ChatGPTAuthError.invalidIDToken("wrong issuer") }
        guard claims.aud.values.contains(clientID) else { throw ChatGPTAuthError.invalidIDToken("wrong audience") }
        guard Date(timeIntervalSince1970: claims.exp) > Date().addingTimeInterval(-60) else {
            throw ChatGPTAuthError.invalidIDToken("expired")
        }
        if let nonce, claims.nonce != nonce { throw ChatGPTAuthError.invalidIDToken("wrong nonce") }
        return Identity(subject: claims.sub, email: claims.email)
    }
}

/// OpenAI's OpenID configuration and signing keys, fetched once and kept.
actor OpenIDMetadata {
    struct Document: Decodable {
        var jwks_uri: String
        var revocation_endpoint: String?
    }

    struct KeySet: Decodable {
        struct Key: Decodable {
            var kty: String
            var kid: String?
            var n: String?
            var e: String?
        }

        var keys: [Key]
    }

    let discovery: URL
    let http: HTTPClient
    private var cachedDocument: Document?
    private var keys: [String: SecKey] = [:]
    private var anonymousKey: SecKey?
    private var lastFetch: Date?

    init(discovery: URL, http: HTTPClient) {
        self.discovery = discovery
        self.http = http
    }

    func document() async throws -> Document {
        if let cachedDocument { return cachedDocument }
        let document = try await http.json(Document.self, URLRequest(url: discovery), errors: ChatGPTAuth.oauthError)
        cachedDocument = document
        return document
    }

    /// The RSA key with this id. Keys rotate, so an unknown id fetches the set again, at most once a minute.
    func key(id: String?) async throws -> SecKey {
        if let id, let key = keys[id] { return key }
        if id == nil, let anonymousKey { return anonymousKey }
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 60 {
            throw ChatGPTAuthError.invalidIDToken("unknown signing key")
        }
        guard let url = URL(string: try await document().jwks_uri) else {
            throw ChatGPTAuthError.invalidIDToken("no key set")
        }
        let set = try await http.json(KeySet.self, URLRequest(url: url), errors: ChatGPTAuth.oauthError)
        lastFetch = Date()
        for key in set.keys where key.kty == "RSA" {
            guard let n = key.n.flatMap(Base64URL.decode), let e = key.e.flatMap(Base64URL.decode),
                  let secKey = RSAPublicKey.make(modulus: n, exponent: e) else { continue }
            if let kid = key.kid { keys[kid] = secKey } else { anonymousKey = secKey }
        }
        if let id, let key = keys[id] { return key }
        if id == nil, let key = anonymousKey ?? (keys.count == 1 ? keys.values.first : nil) { return key }
        throw ChatGPTAuthError.invalidIDToken("unknown signing key")
    }
}

/// Builds a Security framework key from a JWK's modulus and exponent (PKCS #1 RSAPublicKey DER).
enum RSAPublicKey {
    static func make(modulus: Data, exponent: Data) -> SecKey? {
        let der = sequence(integer(modulus) + integer(exponent))
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }

    static func integer(_ value: Data) -> Data {
        var bytes = Data(value.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes[bytes.startIndex] & 0x80 != 0 { bytes.insert(0, at: bytes.startIndex) }
        return Data([0x02]) + length(bytes.count) + bytes
    }

    static func sequence(_ content: Data) -> Data {
        Data([0x30]) + length(content.count) + content
    }

    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var rest = count
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

/// Keeps a signed-in account's access token fresh. Refreshes run one at a time: refresh tokens
/// rotate, and two refreshes racing with the same token would end the sign-in.
public actor ChatGPTSession {
    public private(set) var account: ChatGPTAccount
    let auth: ChatGPTAuth
    let save: @Sendable (ChatGPTAccount) -> Void
    private var refreshing: Task<ChatGPTTokens, Error>?

    /// `save` is called with every change so the account can be written to the keychain.
    public init(account: ChatGPTAccount, auth: ChatGPTAuth, save: @escaping @Sendable (ChatGPTAccount) -> Void) {
        self.account = account
        self.auth = auth
        self.save = save
    }

    public func accessToken() async throws -> String {
        guard !signingOut, let tokens = account.tokens else { throw ProviderError.notConnected }
        guard account.canUsePlan else {
            throw ProviderError.forbidden("Using the ChatGPT plan was not allowed at sign-in")
        }
        if tokens.expiresAt.timeIntervalSinceNow > ChatGPTAuth.refreshMargin { return tokens.accessToken }
        return try await refresh().accessToken
    }

    /// Renews the tokens. Without `force` a renewal before `earliest_refresh_at` is skipped while the
    /// token still works; `force` is for a token the server just rejected.
    @discardableResult
    public func refresh(force: Bool = false) async throws -> ChatGPTTokens {
        guard !signingOut else { throw ProviderError.notConnected }
        if let refreshing { return try await refreshing.value }
        guard let tokens = account.tokens else { throw ProviderError.notConnected }
        if !force, let earliest = tokens.earliestRefreshAt, earliest > Date(), tokens.expiresAt > Date() {
            return tokens
        }
        let task = Task { [auth, account] in try await auth.refresh(account) }
        refreshing = task
        defer { refreshing = nil }
        // the actor can sign out or take a new sign-in while this waits: a result only applies to
        // the token set it renewed
        let renewing = tokens.refreshToken
        do {
            let renewed = try await task.value
            guard account.tokens?.refreshToken == renewing else {
                // replaced meanwhile by a new sign-in (use it) or by a sign-out
                if !signingOut, let current = account.tokens { return current }
                throw ProviderError.notConnected
            }
            account.tokens = renewed
            save(account)
            return renewed
        } catch ProviderError.unauthorized(let message) {
            // the refresh token is gone for good: keep the registration for the next sign-in
            if account.tokens?.refreshToken == renewing {
                account.tokens = nil
                save(account)
            } else if !signingOut, let current = account.tokens {
                // a new sign-in arrived while the old token failed
                return current
            }
            throw ProviderError.unauthorized(message)
        }
    }

    /// Replaces the account after a new sign-in of the same user.
    public func replace(with account: ChatGPTAccount) {
        self.account = account
        save(account)
    }

    /// Revokes the sign-in and forgets the tokens. Returns false when OpenAI could not confirm the
    /// revocation; the tokens are cleared here either way.
    public func signOut() async -> Bool {
        signingOut = true
        defer { signingOut = false }
        let before = account.tokens
        // a renewal in flight rotates the refresh token: take its result straight from the task, since
        // the renewal itself may not have stored it yet when this resumes
        var live: [ChatGPTTokens] = []
        if let refreshing, let renewed = try? await refreshing.value { live.append(renewed) }
        // the current set, unless it is the one that renewal just replaced
        if let current = account.tokens, !live.contains(where: { $0.refreshToken == current.refreshToken }),
           live.isEmpty || current.refreshToken != before?.refreshToken {
            live.append(current)
        }
        let registration = account
        account.tokens = nil
        save(account)
        var confirmed = true
        for tokens in live {
            var revoking = registration
            revoking.tokens = tokens
            if !(await auth.revoke(revoking)) { confirmed = false }
        }
        return confirmed
    }

    private var signingOut = false
}

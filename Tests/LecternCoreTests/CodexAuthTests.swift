import XCTest
@testable import LecternCore

/// The Codex sign-in runs for real against a local listener on a test port; OpenAI's endpoints are
/// answered by MockHTTP. The flow, parameters and headers are the ones the Codex CLI's login uses.
final class CodexAuthTests: XCTestCase {
    static let endpoints = CodexAuth.Endpoints(authorize: URL(string: "https://auth.test/oauth/authorize")!,
                                               token: URL(string: "https://auth.test/oauth/token")!)
    static let port: UInt16 = 14555

    func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    }

    /// An unsigned token with the claims the Codex CLI reads.
    func idToken(email: String = "student@example.com", account: String = "acct-1", plan: String? = "plus") throws -> String {
        var auth: [String: Any] = ["chatgpt_account_id": account, "chatgpt_user_id": "user-1"]
        if let plan { auth["chatgpt_plan_type"] = plan }
        let claims: [String: Any] = ["iss": "https://auth.openai.com", "sub": "sub-1", "email": email, "https://api.openai.com/auth": auth]
        let header = Base64URL.encode(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"]))
        return "\(header).\(Base64URL.encode(try JSONSerialization.data(withJSONObject: claims))).sig"
    }

    func tokenJSON(access: String, refresh: String?, idToken: String?, expiresIn: Int = 864_000) -> String {
        var object: [String: Any] = ["access_token": access, "token_type": "Bearer", "expires_in": expiresIn]
        if let refresh { object["refresh_token"] = refresh }
        if let idToken { object["id_token"] = idToken }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testTheRegisteredCallbackAndTheAuthorizeURL() {
        XCTAssertEqual(CodexAuth().redirectURI, "http://localhost:1455/auth/callback")
        XCTAssertEqual(CodexAuth.clientID, "app_EMoamEEZ73f0CkXaXp7hrann")
        let auth = CodexAuth(endpoints: Self.endpoints, callbackPort: Self.port)
        let url = auth.authorizeURL(state: "st", challenge: "ch")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://auth.test/oauth/authorize?"))
        let items = query(url)
        XCTAssertEqual(items, ["client_id": CodexAuth.clientID, "response_type": "code",
                               "redirect_uri": "http://localhost:\(Self.port)/auth/callback",
                               "scope": "openid email profile offline_access", "state": "st", "code_challenge": "ch",
                               "code_challenge_method": "S256", "prompt": "login", "id_token_add_organizations": "true",
                               "codex_cli_simplified_flow": "true"])
        XCTAssertTrue(url.query!.contains("scope=openid%20email"))
        // PKCE: a 128-character verifier of 96 random bytes, and the state as 32 hex digits
        XCTAssertEqual(CodexAuth.codeVerifier().count, 128)
        XCTAssertNotEqual(CodexAuth.codeVerifier(), CodexAuth.codeVerifier())
        XCTAssertEqual(CodexAuth.randomState().count, 32)
        XCTAssertNil(CodexAuth.randomState().rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789abcdef").inverted))
        XCTAssertEqual(CodexAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testSignInExchangesTheCodeAndReadsTheIDToken() async throws {
        let browser = ChatGPTAuthTests.Browser { query in ["code": "code-1", "state": query["state"]!] }
        let token = try idToken()
        let session = MockHTTP.session { [self] recorded in
            XCTAssertEqual(recorded.request.url?.path, "/oauth/token")
            return .json(tokenJSON(access: "access-1", refresh: "refresh-1", idToken: token))
        }
        let auth = CodexAuth(endpoints: Self.endpoints, callbackPort: Self.port, session: session)
        let account = try await auth.signIn(timeout: 20) { browser.open($0) }

        XCTAssertEqual(account.accessToken, "access-1")
        XCTAssertEqual(account.refreshToken, "refresh-1")
        XCTAssertEqual(account.idToken, token)
        XCTAssertEqual(account.accountID, "acct-1")
        XCTAssertEqual(account.email, "student@example.com")
        XCTAssertEqual(account.planType, "plus")
        XCTAssertEqual(account.expiresAt.timeIntervalSinceNow, 864_000, accuracy: 30)
        XCTAssertEqual(account.lastRefresh.timeIntervalSinceNow, 0, accuracy: 30)

        let exchange = try XCTUnwrap(MockHTTP.requests.first)
        XCTAssertEqual(exchange.header("Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(exchange.header("Accept"), "application/json")
        let form = exchange.form
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["client_id"], CodexAuth.clientID)
        XCTAssertEqual(form["code"], "code-1")
        XCTAssertEqual(form["redirect_uri"], "http://localhost:\(Self.port)/auth/callback")
        XCTAssertEqual(CodexAuth.challenge(for: form["code_verifier"]!), browser.authorizeQuery["code_challenge"])
        XCTAssertEqual(form["code_verifier"]?.count, 128)
    }

    func testSignInRejectsAForeignStateADeclineAndABusyPort() async throws {
        let session = MockHTTP.session { _ in .json("{}", status: 500) }
        let auth = CodexAuth(endpoints: Self.endpoints, callbackPort: Self.port, session: session)
        do {
            _ = try await auth.signIn(timeout: 3) { ChatGPTAuthTests.Browser { _ in ["code": "c", "state": "forged"] }.open($0) }
            XCTFail("a forged state must not end the sign-in")
        } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .timedOut)
        }
        do {
            _ = try await auth.signIn(timeout: 20) { ChatGPTAuthTests.Browser { ["error": "access_denied", "state": $0["state"]!] }.open($0) }
            XCTFail("expected a cancel")
        } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .cancelled)
        }
        XCTAssertTrue(MockHTTP.requests.isEmpty)

        // the registered port is taken: say so instead of waiting
        let taken = try await LoopbackServer.start(path: "/x", state: "s", page: "", port: Self.port)
        defer { taken.stop() }
        do {
            _ = try await auth.signIn(timeout: 3) { _ in }
            XCTFail("expected the port error")
        } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .portInUse(Int(Self.port)))
        }
    }

    func testTheCallbackIsReachableAsLocalhostOnBothAddressFamilies() async throws {
        let server = try await LoopbackServer.start(path: "/auth/callback", state: "s", page: "done", port: Self.port)
        defer { server.stop() }
        for host in ["127.0.0.1", "[::1]"] {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://\(host):\(Self.port)/other")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404, host)
            XCTAssertEqual(data.count, 0)
        }
        _ = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://localhost:\(Self.port)/auth/callback?code=c&state=s")!)
        let callback = try await server.callback(timeout: 5)
        XCTAssertEqual(callback["code"], "c")
    }

    func testClaimsWithoutAPlanAreFree() throws {
        let claims = try XCTUnwrap(CodexAuth.claims(of: try idToken(plan: nil)))
        XCTAssertEqual(claims.accountID, "acct-1")
        XCTAssertNil(claims.planType)
        XCTAssertNil(CodexAuth.claims(of: "not.a.token"))
        let account = try CodexAuth.account(from: CodexAuth.TokenResponse(access_token: "a", refresh_token: "r", id_token: try idToken(plan: nil),
                                                                          expires_in: 10), keeping: nil)
        XCTAssertEqual(account.planType, "free")
    }

    func account(expiresIn: TimeInterval) -> CodexAccount {
        CodexAccount(idToken: "id", accessToken: "access-old", refreshToken: "refresh-1", accountID: "acct-1", email: "student@example.com",
                     planType: "plus", expiresAt: Date().addingTimeInterval(expiresIn), lastRefresh: Date())
    }

    final class Saved: @unchecked Sendable {
        private let lock = NSLock()
        private var accounts: [CodexAccount?] = []
        func add(_ account: CodexAccount?) { lock.withLock { accounts.append(account) } }
        var all: [CodexAccount?] { lock.withLock { accounts } }
    }

    func testRefreshRunsFourDaysBeforeExpiryAndOnceForConcurrentCallers() async throws {
        let token = try idToken(account: "acct-2")
        let session = MockHTTP.session { [self] _ in
            Thread.sleep(forTimeInterval: 0.2)
            return .json(tokenJSON(access: "access-new", refresh: "refresh-2", idToken: token))
        }
        let saved = Saved()
        let auth = CodexAuth(endpoints: Self.endpoints, session: session)
        // three days left: due
        let codex = CodexSession(account: account(expiresIn: 3 * 86_400), auth: auth) { saved.add($0) }
        async let first = codex.accessToken()
        async let second = codex.accessToken()
        let tokens = try await [first, second]
        XCTAssertEqual(tokens, ["access-new", "access-new"])

        let refreshes = MockHTTP.requests
        XCTAssertEqual(refreshes.count, 1)
        XCTAssertEqual(refreshes[0].form, ["client_id": CodexAuth.clientID, "grant_type": "refresh_token", "refresh_token": "refresh-1",
                                           "scope": "openid profile email"])
        let stored = try XCTUnwrap(saved.all.last ?? nil)
        XCTAssertEqual(stored.refreshToken, "refresh-2")
        XCTAssertEqual(stored.accountID, "acct-2")
        let accountID = await codex.accountID()
        XCTAssertEqual(accountID, "acct-2")
        let again = try await codex.accessToken()
        XCTAssertEqual(again, "access-new")
        XCTAssertEqual(MockHTTP.requests.count, 1)

        // five days left: not yet
        let fresh = CodexSession(account: account(expiresIn: 5 * 86_400), auth: auth) { saved.add($0) }
        let kept = try await fresh.accessToken()
        XCTAssertEqual(kept, "access-old")
        XCTAssertEqual(MockHTTP.requests.count, 1)
    }

    func testAReusedRefreshTokenEndsTheSignInAndAServerErrorIsRetried() async throws {
        var session = MockHTTP.session { _ in
            .json(#"{"error":"invalid_grant","error_description":"refresh_token_reused"}"#, status: 400)
        }
        let saved = Saved()
        var codex = CodexSession(account: account(expiresIn: 10), auth: CodexAuth(endpoints: Self.endpoints, session: session)) { saved.add($0) }
        do {
            _ = try await codex.accessToken()
            XCTFail("expected a sign-in error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unauthorized("refresh_token_reused"))
        }
        XCTAssertEqual(MockHTTP.requests.count, 1)
        XCTAssertEqual(saved.all.count, 1)
        XCTAssertNil(saved.all.last ?? nil)
        let after = await codex.account
        XCTAssertNil(after)

        let counter = Counter()
        session = MockHTTP.session { [self] _ in
            if counter.next() < 2 { return .json(#"{"error":"server_error"}"#, status: 502) }
            return .json(tokenJSON(access: "access-new", refresh: "refresh-2", idToken: nil))
        }
        codex = CodexSession(account: account(expiresIn: 10), auth: CodexAuth(endpoints: Self.endpoints, session: session)) { saved.add($0) }
        let renewed = try await codex.accessToken()
        XCTAssertEqual(renewed, "access-new")
        XCTAssertEqual(MockHTTP.requests.count, 3)
        // the ID token and account stay when the renewal brings none
        let stored = try XCTUnwrap(saved.all.last ?? nil)
        XCTAssertEqual(stored.idToken, "id")
        XCTAssertEqual(stored.accountID, "acct-1")
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
    }

    func testTheProviderTalksToTheCodexBackendAsTheCLI() async throws {
        let stream = sse([
            (nil, #"{"type":"response.created","response":{"id":"r","model":"gpt-6.1-sol"}}"#),
            (nil, #"{"type":"response.output_text.delta","delta":"Hi"}"#),
            (nil, #"{"type":"response.completed","response":{"model":"gpt-6.1-sol","usage":{"input_tokens":3,"output_tokens":1}}}"#),
        ])
        let session = MockHTTP.session { _ in .events(stream) }
        let codex = CodexSession(account: account(expiresIn: 10 * 86_400), auth: CodexAuth(endpoints: Self.endpoints, session: session)) { _ in }
        let provider = OpenAIProvider(credential: .codex(codex), session: session)
        XCTAssertEqual(provider.kind, .chatGPT)
        let models = try await provider.models().map(\.id)
        XCTAssertEqual(models.first, "gpt-6.1-sol")
        let answer = try await provider.complete(CompletionRequest(model: "gpt-6.1-sol", system: "", messages: [ChatMessage(.user, "hello")],
                                                                   maxOutputTokens: 500))
        XCTAssertEqual(answer.text, "Hi")

        let sent = try XCTUnwrap(MockHTTP.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
        XCTAssertEqual(sent.header("Authorization"), "Bearer access-old")
        XCTAssertEqual(sent.header("Chatgpt-Account-Id"), "acct-1")
        XCTAssertEqual(sent.header("Originator"), "codex-tui")
        XCTAssertEqual(sent.header("User-Agent"), "codex-tui/0.154.0 (Mac OS 26.5.2; arm64) iTerm.app/3.6.11 (codex-tui; 0.154.0)")
        XCTAssertEqual(sent.header("Accept"), "text/event-stream")
        XCTAssertEqual(sent.json["instructions"] as? String, "")
        XCTAssertEqual(sent.json["store"] as? Bool, false)
        XCTAssertEqual(sent.json["stream"] as? Bool, true)
        XCTAssertEqual(sent.json["max_output_tokens"] as? Int, 500)
    }
}

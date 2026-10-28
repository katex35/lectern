import CryptoKit
import Security
import XCTest
@testable import LecternCore

/// The sign-in runs for real against a local listener; OpenAI's endpoints are answered by MockHTTP
/// and the ID tokens are signed with a key made for the test.
final class ChatGPTAuthTests: XCTestCase {
    static let endpoints = ChatGPTAuth.Endpoints(
        authorize: URL(string: "https://auth.test/api/accounts/authorize")!,
        token: URL(string: "https://auth.test/api/accounts/oauth/token")!,
        discovery: URL(string: "https://auth.test/.well-known/openid-configuration")!)

    var signingKey: SecKey!
    var jwk: [String: String]!

    override func setUpWithError() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        signingKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(signingKey))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let (n, e) = try Self.modulusAndExponent(der)
        jwk = ["kty": "RSA", "kid": "key-1", "alg": "RS256", "use": "sig", "n": Base64URL.encode(n), "e": Base64URL.encode(e)]
    }

    /// Reads SEQUENCE { INTEGER n, INTEGER e } (PKCS #1).
    static func modulusAndExponent(_ der: Data) throws -> (Data, Data) {
        var bytes = [UInt8](der)
        func take() throws -> (UInt8, [UInt8]) {
            guard bytes.count >= 2 else { throw CocoaError(.coderReadCorrupt) }
            let tag = bytes.removeFirst()
            var length = Int(bytes.removeFirst())
            if length & 0x80 != 0 {
                let count = length & 0x7F
                length = bytes.prefix(count).reduce(0) { $0 << 8 | Int($1) }
                bytes.removeFirst(count)
            }
            let value = Array(bytes.prefix(length))
            bytes.removeFirst(length)
            return (tag, value)
        }
        let (tag, content) = try take()
        guard tag == 0x30 else { throw CocoaError(.coderReadCorrupt) }
        bytes = content
        let n = try take().1
        let e = try take().1
        return (Data(n), Data(e))
    }

    func idToken(_ claims: [String: Any], kid: String = "key-1") throws -> String {
        let header = Base64URL.encode(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT", "kid": kid]))
        let payload = Base64URL.encode(try JSONSerialization.data(withJSONObject: claims))
        let signed = Data("\(header).\(payload)".utf8)
        let signature = try XCTUnwrap(SecKeyCreateSignature(signingKey, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, nil) as Data?)
        return "\(header).\(payload).\(Base64URL.encode(signature))"
    }

    func claims(client: String = "oaiapp_test", nonce: String?, subject: String = "user-1",
                expires: TimeInterval = 3600) -> [String: Any] {
        var claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": client, "sub": subject, "email": "student@example.com",
                                     "exp": Date().addingTimeInterval(expires).timeIntervalSince1970]
        if let nonce { claims["nonce"] = nonce }
        return claims
    }

    /// Discovery and the key set, shared by every handler below.
    func metadataReply(_ recorded: MockHTTP.Recorded) throws -> MockHTTP.Reply? {
        switch recorded.request.url?.path {
        case "/.well-known/openid-configuration":
            return .json(#"{"issuer":"https://auth.openai.com","jwks_uri":"https://auth.test/jwks","revocation_endpoint":"https://auth.test/revoke"}"#)
        case "/jwks":
            return .json(String(decoding: try JSONSerialization.data(withJSONObject: ["keys": [jwk!]]), as: UTF8.self))
        default:
            return nil
        }
    }

    func tokenJSON(access: String, refresh: String?, idToken: String?, scope: String = ChatGPTAuth.scope) -> String {
        var object: [String: Any] = ["access_token": access, "token_type": "Bearer", "expires_in": 3600, "scope": scope]
        if let refresh { object["refresh_token"] = refresh }
        if let idToken { object["id_token"] = idToken }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testPKCEChallengeMatchesTheRFCExample() {
        // RFC 7636, appendix B
        XCTAssertEqual(ChatGPTAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testJWKBecomesTheSameKey() throws {
        let rebuilt = try XCTUnwrap(RSAPublicKey.make(modulus: Base64URL.decode(jwk["n"]!)!, exponent: Base64URL.decode(jwk["e"]!)!))
        let original = try XCTUnwrap(SecKeyCopyPublicKey(signingKey))
        XCTAssertEqual(SecKeyCopyExternalRepresentation(rebuilt, nil) as Data?, SecKeyCopyExternalRepresentation(original, nil) as Data?)
    }

    func testAuthorizeURLForFirstAndReturningSignIn() throws {
        let auth = ChatGPTAuth(appName: "Lectern", hostID: "host-1", endpoints: Self.endpoints)
        func query(_ url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
        }
        let first = query(auth.authorizeURL(previous: nil, redirect: "http://127.0.0.1:5000/auth/callback", state: "s",
                                            nonce: "n", challenge: "c"))
        XCTAssertEqual(first["client_id"], "dynamic_agent_client")
        XCTAssertEqual(first["agent_name_hint"], "Lectern")
        XCTAssertEqual(first["ext_agent_host_id"], "host-1")
        XCTAssertEqual(first["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        XCTAssertEqual(first["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(first["redirect_uri"], "http://127.0.0.1:5000/auth/callback")
        XCTAssertEqual(first["code_challenge_method"], "S256")
        XCTAssertEqual(first["response_type"], "code")
        XCTAssertNil(first["id_token_hint"])

        let previous = ChatGPTAccount(clientID: "oaiapp_x", hostID: "host-1", subject: "u", email: "a@b.c",
                                      tokens: ChatGPTTokens(idToken: "old.id.token", accessToken: "a", refreshToken: "r",
                                                            expiresAt: Date(), scopes: []))
        let url = auth.authorizeURL(previous: previous, redirect: "http://127.0.0.1:5001/auth/callback", state: "s", nonce: "n",
                                    challenge: "c")
        let again = query(url)
        XCTAssertEqual(again["client_id"], "oaiapp_x")
        XCTAssertNil(again["agent_name_hint"])
        XCTAssertEqual(again["id_token_hint"], "old.id.token")
        XCTAssertEqual(again["login_hint"], "a@b.c")
        // every value is fully encoded: spaces and reserved characters never appear raw
        XCTAssertTrue(url.query!.contains("scope=openid%20profile"))
        XCTAssertTrue(url.query!.contains("login_hint=a%40b.c"))
    }

    /// Plays the browser: reads the authorize URL and calls the local redirect like OpenAI would.
    final class Browser: @unchecked Sendable {
        private let lock = NSLock()
        private var query: [String: String] = [:]
        var reply: @Sendable ([String: String]) -> [String: String]

        init(reply: @escaping @Sendable ([String: String]) -> [String: String]) {
            self.reply = reply
        }

        var authorizeQuery: [String: String] { lock.withLock { query } }

        func open(_ url: URL) {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            lock.withLock { self.query = query }
            var callback = URLComponents(string: query["redirect_uri"]!)!
            callback.queryItems = reply(query).map { URLQueryItem(name: $0.key, value: $0.value) }
            let target = callback.url!
            Task.detached {
                // a stray request first, as browsers do; it must not end the wait
                var favicon = URLComponents(url: target, resolvingAgainstBaseURL: false)!
                favicon.path = "/favicon.ico"
                favicon.query = nil
                _ = try? await URLSession(configuration: .ephemeral).data(from: favicon.url!)
                _ = try? await URLSession(configuration: .ephemeral).data(from: target)
            }
        }
    }

    func testFirstSignInRegistersAndVerifiesTheIDToken() async throws {
        let browser = Browser { query in ["code": "code-1", "state": query["state"]!, "client_id": "oaiapp_test",
                                          "scope": ChatGPTAuth.scope] }
        let session = MockHTTP.session { [self] recorded in
            if let reply = try metadataReply(recorded) { return reply }
            let nonce = browser.authorizeQuery["nonce"]
            return .json(tokenJSON(access: "access-1", refresh: "refresh-1", idToken: try idToken(claims(nonce: nonce))))
        }
        let auth = ChatGPTAuth(appName: "Lectern", hostID: "host-1", endpoints: Self.endpoints, session: session)
        let account = try await auth.signIn(timeout: 20) { browser.open($0) }

        XCTAssertEqual(account.clientID, "oaiapp_test")
        XCTAssertEqual(account.subject, "user-1")
        XCTAssertEqual(account.email, "student@example.com")
        XCTAssertEqual(account.hostID, "host-1")
        XCTAssertEqual(account.tokens?.accessToken, "access-1")
        XCTAssertEqual(account.tokens?.refreshToken, "refresh-1")
        XCTAssertTrue(account.canUsePlan)
        XCTAssertEqual(account.tokens?.expiresAt.timeIntervalSinceNow ?? 0, 3600, accuracy: 30)

        let exchange = try XCTUnwrap(MockHTTP.requests.first { $0.request.url?.path == "/api/accounts/oauth/token" })
        let form = exchange.form
        XCTAssertEqual(exchange.header("Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["client_id"], "oaiapp_test")
        XCTAssertEqual(form["code"], "code-1")
        XCTAssertEqual(form["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(form["redirect_uri"], browser.authorizeQuery["redirect_uri"])
        XCTAssertTrue(form["redirect_uri"]!.hasPrefix("http://127.0.0.1:"))
        XCTAssertEqual(ChatGPTAuth.challenge(for: form["code_verifier"]!), browser.authorizeQuery["code_challenge"])
    }

    func testSignInRejectsAForeignStateAndADeclinedConsent() async throws {
        let session = MockHTTP.session { [self] recorded in try metadataReply(recorded) ?? .json("{}", status: 500) }
        let auth = ChatGPTAuth(appName: "Lectern", hostID: "h", endpoints: Self.endpoints, session: session)
        // a stray callback with another state is turned away and the wait goes on
        do {
            _ = try await auth.signIn(timeout: 3) { Browser { _ in ["code": "c", "state": "forged", "client_id": "oaiapp_x"] }.open($0) }
            XCTFail("a forged state must not end the sign-in")
        } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .timedOut)
        }
        do {
            _ = try await auth.signIn(timeout: 20) { Browser { ["error": "access_denied", "state": $0["state"]!] }.open($0) }
            XCTFail("expected a cancel")
        } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .cancelled)
        }
        XCTAssertFalse(MockHTTP.requests.contains { $0.request.url?.path == "/api/accounts/oauth/token" })
    }

    func testIDTokenChecks() async throws {
        let session = MockHTTP.session { [self] recorded in try metadataReply(recorded) ?? .json("{}", status: 404) }
        let auth = ChatGPTAuth(appName: "Lectern", hostID: "h", endpoints: Self.endpoints, session: session)
        let good = try idToken(claims(nonce: "n1"))
        let identity = try await auth.validate(idToken: good, clientID: "oaiapp_test", nonce: "n1")
        XCTAssertEqual(identity, ChatGPTAuth.Identity(subject: "user-1", email: "student@example.com"))

        func rejects(_ token: String, client: String = "oaiapp_test", nonce: String? = "n1", _ reason: String) async {
            do {
                _ = try await auth.validate(idToken: token, clientID: client, nonce: nonce)
                XCTFail("accepted: \(reason)")
            } catch {
                XCTAssertEqual(error as? ChatGPTAuthError, .invalidIDToken(reason))
            }
        }
        await rejects(good, client: "oaiapp_other", "wrong audience")
        await rejects(good, nonce: "n2", "wrong nonce")
        await rejects(try idToken(claims(nonce: "n1", expires: -600)), "expired")
        var forged = claims(nonce: "n1")
        forged["iss"] = "https://evil.test"
        await rejects(try idToken(forged), "wrong issuer")
        // payload swapped after signing
        let parts = good.split(separator: ".")
        let otherPayload = try idToken(claims(nonce: "n1", subject: "someone-else")).split(separator: ".")[1]
        await rejects("\(parts[0]).\(otherPayload).\(parts[2])", "bad signature")
        await rejects(try idToken(claims(nonce: "n1"), kid: "unknown"), "unknown signing key")
    }

    func account(expiresIn: TimeInterval, refresh: String = "refresh-1") -> ChatGPTAccount {
        ChatGPTAccount(clientID: "oaiapp_test", hostID: "h", subject: "user-1", email: "student@example.com",
                       tokens: ChatGPTTokens(idToken: "id", accessToken: "access-old", refreshToken: refresh,
                                             expiresAt: Date().addingTimeInterval(expiresIn),
                                             scopes: ChatGPTAuth.scope.split(separator: " ").map(String.init)))
    }

    final class Saved: @unchecked Sendable {
        private let lock = NSLock()
        private var accounts: [ChatGPTAccount] = []
        func add(_ account: ChatGPTAccount) { lock.withLock { accounts.append(account) } }
        var all: [ChatGPTAccount] { lock.withLock { accounts } }
    }

    func testRefreshRotatesOnceForConcurrentCallers() async throws {
        let session = MockHTTP.session { [self] recorded in
            if let reply = try metadataReply(recorded) { return reply }
            Thread.sleep(forTimeInterval: 0.2)
            return .json(tokenJSON(access: "access-new", refresh: "refresh-2", idToken: try idToken(claims(nonce: nil))))
        }
        let saved = Saved()
        let auth = ChatGPTAuth(appName: "Lectern", hostID: "h", endpoints: Self.endpoints, session: session)
        let chatGPT = ChatGPTSession(account: account(expiresIn: 60), auth: auth) { saved.add($0) }
        async let first = chatGPT.accessToken()
        async let second = chatGPT.accessToken()
        let tokens = try await [first, second]
        XCTAssertEqual(tokens, ["access-new", "access-new"])

        let refreshes = MockHTTP.requests.filter { $0.request.url?.path == "/api/accounts/oauth/token" }
        XCTAssertEqual(refreshes.count, 1)
        XCTAssertEqual(refreshes[0].form, ["grant_type": "refresh_token", "client_id": "oaiapp_test",
                                           "refresh_token": "refresh-1", "resource": "https://api.openai.com/v1"])
        XCTAssertEqual(saved.all.last?.tokens?.refreshToken, "refresh-2")
        // still fresh: no second refresh
        let third = try await chatGPT.accessToken()
        XCTAssertEqual(third, "access-new")
        XCTAssertEqual(MockHTTP.requests.filter { $0.request.url?.path == "/api/accounts/oauth/token" }.count, 1)
    }

    func testTerminalRefreshErrorEndsTheSignInButKeepsTheRegistration() async throws {
        let session = MockHTTP.session { _ in
            .json(#"{"error":"refresh_token_reused","error_description":"Refresh token was already used"}"#, status: 400)
        }
        let saved = Saved()
        let auth = ChatGPTAuth(appName: "Lectern", hostID: "h", endpoints: Self.endpoints, session: session)
        let chatGPT = ChatGPTSession(account: account(expiresIn: 10), auth: auth) { saved.add($0) }
        do {
            _ = try await chatGPT.accessToken()
            XCTFail("expected a sign-in error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unauthorized("Refresh token was already used"))
        }
        XCTAssertNil(saved.all.last?.tokens)
        XCTAssertEqual(saved.all.last?.clientID, "oaiapp_test")
        let after = await chatGPT.account
        XCTAssertNil(after.tokens)
    }

    func testTemporaryRefreshFailureKeepsTheTokens() async throws {
        let session = MockHTTP.session { _ in .json(#"{"error":"server_error"}"#, status: 502) }
        let saved = Saved()
        let auth = ChatGPTAuth(appName: "Lectern", hostID: "h", endpoints: Self.endpoints, session: session)
        let chatGPT = ChatGPTSession(account: account(expiresIn: 10), auth: auth) { saved.add($0) }
        do {
            _ = try await chatGPT.accessToken()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? ProviderError)?.isTemporary, true)
        }
        XCTAssertTrue(saved.all.isEmpty)
        let after = await chatGPT.account
        XCTAssertEqual(after.tokens?.refreshToken, "refresh-1")
    }

    func testNonTerminalRejectionKeepsTheTokens() async throws {
        // a proxy's login page or an unknown code is no reason to forget the sign-in
        let replies = [MockHTTP.Reply(status: 401, headers: ["Content-Type": "text/html"], chunks: [Data("<html>Log in</html>".utf8)]),
                       MockHTTP.Reply.json(#"{"error":"unauthorized_client"}"#, status: 401)]
        for reply in replies {
            let session = MockHTTP.session { _ in reply }
            let saved = Saved()
            let auth = ChatGPTAuth(appName: "Lectern", hostID: "h", endpoints: Self.endpoints, session: session)
            let chatGPT = ChatGPTSession(account: account(expiresIn: 10), auth: auth) { saved.add($0) }
            do {
                _ = try await chatGPT.accessToken()
                XCTFail("expected an error")
            } catch {
                if case .unauthorized = error as? ProviderError { XCTFail("must not end the sign-in: \(error)") }
            }
            XCTAssertTrue(saved.all.isEmpty)
            let after = await chatGPT.account
            XCTAssertEqual(after.tokens?.refreshToken, "refresh-1")
        }
    }

    /// Holds the token endpoint's answer until the test lets it go.
    final class Gate: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        func wait() { _ = semaphore.wait(timeout: .now() + 10) }
        func open() { semaphore.signal() }
    }

    func waitForTokenRequest() async throws {
        for _ in 0..<100 where !MockHTTP.requests.contains(where: { $0.request.url?.path == "/api/accounts/oauth/token" }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testSignOutDuringARefreshRevokesTheRenewedToken() async throws {
        let gate = Gate()
        let session = MockHTTP.session { [self] recorded in
            if let reply = try metadataReply(recorded) { return reply }
            if recorded.request.url?.path == "/revoke" { return .json("") }
            gate.wait()
            return .json(tokenJSON(access: "access-new", refresh: "refresh-2", idToken: nil))
        }
        let saved = Saved()
        let auth = ChatGPTAuth(appName: "Lectern", hostID: "h", endpoints: Self.endpoints, session: session)
        let chatGPT = ChatGPTSession(account: account(expiresIn: 10), auth: auth) { saved.add($0) }
        let renewing = Task { try await chatGPT.accessToken() }
        try await waitForTokenRequest()
        let signingOut = Task { await chatGPT.signOut() }
        try await Task.sleep(nanoseconds: 300_000_000)
        // nothing may start a new renewal while signing out
        do {
            _ = try await chatGPT.refresh(force: true)
            XCTFail("expected notConnected")
        } catch {
            XCTAssertEqual(error as? ProviderError, .notConnected)
        }
        gate.open()
        _ = try? await renewing.value
        let confirmed = await signingOut.value
        XCTAssertTrue(confirmed)

        let revoke = try XCTUnwrap(MockHTTP.requests.first { $0.request.url?.path == "/revoke" })
        XCTAssertEqual(revoke.form["token"], "refresh-2")
        let after = await chatGPT.account
        XCTAssertNil(after.tokens)
        XCTAssertNil(saved.all.last?.tokens)
        XCTAssertEqual(MockHTTP.requests.filter { $0.request.url?.path == "/api/accounts/oauth/token" }.count, 1)
    }

    func testNewSignInDuringAFailingRefreshIsKept() async throws {
        let gate = Gate()
        let session = MockHTTP.session { _ in
            gate.wait()
            return .json(#"{"error":"refresh_token_reused"}"#, status: 400)
        }
        let saved = Saved()
        let auth = ChatGPTAuth(appName: "Lectern", hostID: "h", endpoints: Self.endpoints, session: session)
        let chatGPT = ChatGPTSession(account: account(expiresIn: 10), auth: auth) { saved.add($0) }
        let renewing = Task { try await chatGPT.accessToken() }
        try await waitForTokenRequest()
        var fresh = account(expiresIn: 3000, refresh: "refresh-new")
        fresh.tokens?.accessToken = "access-fresh"
        await chatGPT.replace(with: fresh)
        gate.open()
        let token = try await renewing.value
        XCTAssertEqual(token, "access-fresh")
        let after = await chatGPT.account
        XCTAssertEqual(after.tokens?.refreshToken, "refresh-new")
        XCTAssertEqual(saved.all.last?.tokens?.refreshToken, "refresh-new")
    }

    func testPlanAnswersRetryOnceWithARefreshedToken() async throws {
        let stream = sse([
            ("response.output_text.delta", #"{"type":"response.output_text.delta","delta":"ok"}"#),
            ("response.completed", #"{"type":"response.completed","response":{"model":"gpt-6"}}"#),
        ])
        let session = MockHTTP.session { [self] recorded in
            if let reply = try metadataReply(recorded) { return reply }
            if recorded.request.url?.path == "/api/accounts/oauth/token" {
                return .json(tokenJSON(access: "access-new", refresh: "refresh-2", idToken: nil))
            }
            if recorded.header("Authorization") == "Bearer access-old" {
                return .json(#"{"detail":"Signed identity was not accepted"}"#, status: 401)
            }
            return .events(stream)
        }
        let auth = ChatGPTAuth(appName: "Lectern", hostID: "h", endpoints: Self.endpoints, session: session)
        let chatGPT = ChatGPTSession(account: account(expiresIn: 3000), auth: auth) { _ in }
        let provider = OpenAIProvider(credential: .chatGPT(chatGPT), session: session)
        XCTAssertEqual(provider.kind, .chatGPT)
        var request = CompletionRequest(model: "gpt-6", system: "s", messages: [ChatMessage(.user, "u")])
        request.maxOutputTokens = 1000
        let (text, _) = try await provider.complete(request)
        XCTAssertEqual(text, "ok")
        let calls = MockHTTP.requests.filter { $0.request.url?.path == "/v1/responses" }
        XCTAssertEqual(calls.map { $0.header("Authorization") }, ["Bearer access-old", "Bearer access-new"])
        // the plan route takes no output limit
        XCTAssertNil(calls[1].json["max_output_tokens"])
        XCTAssertEqual(calls[1].json["store"] as? Bool, false)
    }

    func testPlanModelsShowOnlyListedOnes() async throws {
        let session = MockHTTP.session { _ in
            .json(#"""
            {"models":[{"slug":"gpt-6","display_name":"GPT-6","visibility":"list"},
                       {"slug":"gpt-6-internal","display_name":"Internal","visibility":"hide"},
                       {"slug":"gpt-6-mini","display_name":"GPT-6 mini","visibility":"list"}]}
            """#)
        }
        let auth = ChatGPTAuth(appName: "Lectern", hostID: "h", endpoints: Self.endpoints, session: session)
        let chatGPT = ChatGPTSession(account: account(expiresIn: 3000), auth: auth) { _ in }
        let models = try await OpenAIProvider(credential: .chatGPT(chatGPT), session: session).models()
        XCTAssertEqual(models, [ModelInfo(id: "gpt-6", name: "GPT-6"), ModelInfo(id: "gpt-6-mini", name: "GPT-6 mini")])
    }

    func testPlanUseNeedsTheGrantedScope() async {
        var limited = account(expiresIn: 3000)
        limited.tokens?.scopes = ["openid", "profile", "email", "offline_access"]
        let auth = ChatGPTAuth(appName: "Lectern", hostID: "h", endpoints: Self.endpoints, session: MockHTTP.session { _ in .json("{}") })
        let chatGPT = ChatGPTSession(account: limited, auth: auth) { _ in }
        do {
            _ = try await chatGPT.accessToken()
            XCTFail("expected a refusal")
        } catch {
            guard case .forbidden = error as? ProviderError else { return XCTFail("\(error)") }
        }
    }

    func testSignOutRevokesAndForgetsTokens() async throws {
        let session = MockHTTP.session { [self] recorded in try metadataReply(recorded) ?? .json("", status: 200) }
        let saved = Saved()
        let auth = ChatGPTAuth(appName: "Lectern", hostID: "h", endpoints: Self.endpoints, session: session)
        let chatGPT = ChatGPTSession(account: account(expiresIn: 3000), auth: auth) { saved.add($0) }
        let confirmed = await chatGPT.signOut()
        XCTAssertTrue(confirmed)
        let revoke = try XCTUnwrap(MockHTTP.requests.first { $0.request.url?.path == "/revoke" })
        XCTAssertEqual(revoke.form, ["token": "refresh-1", "token_type_hint": "refresh_token", "client_id": "oaiapp_test"])
        XCTAssertNil(saved.all.last?.tokens)
        XCTAssertEqual(saved.all.last?.clientID, "oaiapp_test")
    }
}

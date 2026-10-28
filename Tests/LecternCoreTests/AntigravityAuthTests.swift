import XCTest
@testable import LecternCore

/// The Antigravity sign-in runs for real against a local listener on a test port; Google and Cloud
/// Code are answered by MockHTTP. The parameters, headers and discovery steps are the Antigravity editor's.
final class AntigravityAuthTests: XCTestCase {
    static let endpoints = AntigravityAuth.Endpoints(
        authorize: URL(string: "https://accounts.test/o/oauth2/v2/auth")!,
        token: URL(string: "https://oauth2.test/token")!,
        userInfo: URL(string: "https://www.test/oauth2/v2/userinfo?alt=json")!,
        api: URL(string: "https://cloudcode.test")!)
    static let port: UInt16 = 51122
    static let userAgent = "antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=arm64; cl=1000335682)"

    /// A version source that never reaches the network: the manifest is answered by the mock.
    func auth(_ session: URLSession) -> AntigravityAuth {
        AntigravityAuth(endpoints: Self.endpoints, callbackPort: Self.port, session: session, version: AntigravityVersion(session: session))
    }

    /// Google's and Cloud Code's answers, by path.
    func reply(_ recorded: MockHTTP.Recorded, project: String? = "proj-1", tiers: String = "[]") -> MockHTTP.Reply? {
        switch recorded.request.url?.path {
        case "/manifest/latest-arm64-mac.yml":
            return .json("{}", status: 404)
        case "/token":
            return .json(#"{"access_token":"access-1","refresh_token":"refresh-1","expires_in":3599,"token_type":"Bearer"}"#)
        case "/oauth2/v2/userinfo":
            return .json(#"{"email":"student@gmail.com","verified_email":true}"#)
        case "/v1internal:loadCodeAssist":
            if let project { return .json(#"{"cloudaicompanionProject":"\#(project)","currentTier":{"id":"free-tier"}}"#) }
            return .json(#"{"allowedTiers":\#(tiers),"currentTier":{"id":"legacy-tier"}}"#)
        default:
            return nil
        }
    }

    func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    }

    func testTheRegisteredCallbackAndTheAuthorizeURL() {
        XCTAssertEqual(AntigravityAuth().redirectURI, "http://localhost:51121/oauth-callback")
        let url = auth(.shared).authorizeURL(state: "st")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://accounts.test/o/oauth2/v2/auth?"))
        XCTAssertEqual(query(url), [
            "access_type": "offline", "client_id": AntigravityAuth.clientID, "prompt": "consent",
            "redirect_uri": "http://localhost:\(Self.port)/oauth-callback", "response_type": "code",
            "scope": "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email "
                + "https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/cclog "
                + "https://www.googleapis.com/auth/experimentsandconfigs",
            "state": "st",
        ])
    }

    func testSignInExchangesTheCodeReadsTheEmailAndFindsTheProject() async throws {
        let browser = ChatGPTAuthTests.Browser { query in ["code": "code-1", "state": query["state"]!, "scope": "email"] }
        let session = MockHTTP.session { [self] recorded in try XCTUnwrap(reply(recorded)) }
        let account = try await auth(session).signIn(timeout: 20) { browser.open($0) }

        XCTAssertEqual(account.accessToken, "access-1")
        XCTAssertEqual(account.refreshToken, "refresh-1")
        XCTAssertEqual(account.email, "student@gmail.com")
        XCTAssertEqual(account.projectID, "proj-1")
        XCTAssertEqual(account.expiresAt.timeIntervalSinceNow, 3599, accuracy: 30)

        let calls = MockHTTP.requests.filter { $0.request.url?.path != "/manifest/latest-arm64-mac.yml" }
        XCTAssertEqual(calls.map { $0.request.url?.path }, ["/token", "/oauth2/v2/userinfo", "/v1internal:loadCodeAssist"])
        let form = calls[0].form
        XCTAssertEqual(form, ["code": "code-1", "client_id": AntigravityAuth.clientID, "client_secret": AntigravityAuth.clientSecret,
                              "redirect_uri": "http://localhost:\(Self.port)/oauth-callback", "grant_type": "authorization_code"])
        XCTAssertEqual(calls[1].header("Authorization"), "Bearer access-1")
        XCTAssertEqual(calls[1].header("User-Agent"), Self.userAgent)
        XCTAssertEqual(calls[2].request.url?.absoluteString, "https://cloudcode.test/v1internal:loadCodeAssist")
        XCTAssertEqual(calls[2].header("User-Agent"), Self.userAgent)
        XCTAssertEqual(calls[2].header("Content-Type"), "application/json")
        XCTAssertEqual(calls[2].json["metadata"] as? [String: String], ["ideType": "ANTIGRAVITY"])
    }

    func testAnAccountWithoutAProjectIsOnboardedToItsDefaultTier() async throws {
        let counter = CodexAuthTests.Counter()
        let session = MockHTTP.session { [self] recorded in
            if recorded.request.url?.path == "/v1internal:onboardUser" {
                if counter.next() == 0 { return .json(#"{"name":"operations/1","done":false}"#) }
                return .json(#"{"name":"operations/1","done":true,"response":{"cloudaicompanionProject":{"id":"proj-new"}}}"#)
            }
            return try XCTUnwrap(reply(recorded, project: nil, tiers: #"[{"id":"standard-tier","isDefault":false},{"id":"free-tier","isDefault":true}]"#))
        }
        let project = try await auth(session).projectID(accessToken: "access-1")
        XCTAssertEqual(project, "proj-new")

        let onboarding = MockHTTP.requests.filter { $0.request.url?.path == "/v1internal:onboardUser" }
        XCTAssertEqual(onboarding.count, 2)
        XCTAssertEqual(onboarding[0].json["tier_id"] as? String, "free-tier")
        XCTAssertEqual(onboarding[0].json["metadata"] as? [String: String],
                       ["ide_type": "ANTIGRAVITY", "ide_version": "2.24.0", "ide_name": "antigravity"])
        XCTAssertEqual(onboarding[0].header("User-Agent"), Self.userAgent + " google-api-nodejs-client/10.3.0")
        XCTAssertEqual(onboarding[0].header("X-Goog-Api-Client"), "gl-node/22.21.1")
        XCTAssertEqual(onboarding[0].header("Accept"), "*/*")

        // no default among the tiers: the current one; nothing at all: free-tier
        XCTAssertEqual(AntigravityAuth.defaultTier(["allowedTiers": [["id": "x", "isDefault": false]], "currentTier": ["id": "cur"]]), "cur")
        XCTAssertEqual(AntigravityAuth.defaultTier([:]), "free-tier")
        XCTAssertEqual(AntigravityAuth.project(in: ["projectId": " p2 "]), "p2")
    }

    func testTheVersionComesFromTheManifestElseTheKnownOne() async throws {
        var session = MockHTTP.session { _ in .json("version: 2.25.0\npath: Antigravity.zip\n", headers: ["Content-Type": "text/yaml"]) }
        var version = AntigravityVersion(session: session)
        let agent = await version.userAgent()
        XCTAssertEqual(agent, "antigravity/hub/2.25.0 (aidev_client; os_type=darwin; arch=arm64)")
        XCTAssertEqual(MockHTTP.requests.first?.request.url?.absoluteString, AntigravityVersion.manifest.absoluteString)
        _ = await version.userAgent()
        XCTAssertEqual(MockHTTP.requests.count, 1)

        session = MockHTTP.session { _ in .json("{}", status: 503) }
        version = AntigravityVersion(session: session)
        let fallback = await version.userAgent()
        XCTAssertEqual(fallback, Self.userAgent)
        let onboard = await version.onboardUserAgent()
        XCTAssertEqual(onboard, Self.userAgent + " google-api-nodejs-client/10.3.0")
    }

    func account(expiresIn: TimeInterval, project: String? = "proj-1") -> AntigravityAccount {
        AntigravityAccount(accessToken: "access-old", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(expiresIn),
                           email: "student@gmail.com", projectID: project)
    }

    final class Saved: @unchecked Sendable {
        private let lock = NSLock()
        private var accounts: [AntigravityAccount?] = []
        func add(_ account: AntigravityAccount?) { lock.withLock { accounts.append(account) } }
        var all: [AntigravityAccount?] { lock.withLock { accounts } }
    }

    func testRefreshRunsFiveMinutesBeforeExpiryAndKeepsTheRefreshToken() async throws {
        let session = MockHTTP.session { recorded in
            if recorded.request.url?.path == "/token" {
                Thread.sleep(forTimeInterval: 0.2)
                return .json(#"{"access_token":"access-new","expires_in":3599,"token_type":"Bearer"}"#)
            }
            return .json("{}", status: 404)
        }
        let saved = Saved()
        let antigravity = AntigravitySession(account: account(expiresIn: 200), auth: auth(session)) { saved.add($0) }
        async let first = antigravity.credentials()
        async let second = antigravity.credentials()
        let (one, two) = try await (first, second)
        XCTAssertEqual(one.accessToken, "access-new")
        XCTAssertEqual(two.projectID, "proj-1")

        let refreshes = MockHTTP.requests.filter { $0.request.url?.path == "/token" }
        XCTAssertEqual(refreshes.count, 1)
        XCTAssertEqual(refreshes[0].form, ["client_id": AntigravityAuth.clientID, "client_secret": AntigravityAuth.clientSecret,
                                           "grant_type": "refresh_token", "refresh_token": "refresh-1"])
        XCTAssertEqual(refreshes[0].header("User-Agent"), "Go-http-client/2.0")
        let stored = try XCTUnwrap(saved.all.last ?? nil)
        XCTAssertEqual(stored.refreshToken, "refresh-1")
        XCTAssertEqual(stored.accessToken, "access-new")

        let fresh = AntigravitySession(account: account(expiresIn: 600), auth: auth(session)) { saved.add($0) }
        let kept = try await fresh.credentials()
        XCTAssertEqual(kept.accessToken, "access-old")
        XCTAssertEqual(MockHTTP.requests.filter { $0.request.url?.path == "/token" }.count, 1)
    }

    func testARejectedGrantEndsTheSignInAndAMissingProjectIsFound() async throws {
        var session = MockHTTP.session { _ in .json(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#, status: 400) }
        let saved = Saved()
        var antigravity = AntigravitySession(account: account(expiresIn: 10), auth: auth(session)) { saved.add($0) }
        do {
            _ = try await antigravity.credentials()
            XCTFail("expected a sign-in error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unauthorized("Token has been expired or revoked."))
        }
        XCTAssertNil(saved.all.last ?? nil)

        session = MockHTTP.session { [self] recorded in try XCTUnwrap(reply(recorded)) }
        antigravity = AntigravitySession(account: account(expiresIn: 3600, project: nil), auth: auth(session)) { saved.add($0) }
        let credentials = try await antigravity.credentials()
        XCTAssertEqual(credentials.projectID, "proj-1")
        XCTAssertEqual(credentials.accessToken, "access-old")
        XCTAssertEqual((saved.all.last ?? nil)?.projectID, "proj-1")
        XCTAssertEqual(MockHTTP.requests.filter { $0.request.url?.path == "/v1internal:loadCodeAssist" }.count, 1)
    }

    func testTheTranscriberWrapsTheGeminiRequestTheAntigravityWay() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("piece-\(UUID().uuidString).m4a")
        try Data([1, 2, 3, 4]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let reply = #"{"response":{"candidates":[{"content":{"parts":[{"text":"Bugün geri yayılımı "},{"text":"göreceğiz."}],"role":"model"},"finishReason":"STOP"}],"modelVersion":"gemini-3-flash"},"traceId":"t"}"#
        let session = MockHTTP.session { recorded in
            recorded.request.url?.path == "/v1internal:generateContent" ? .json(reply) : .json("{}", status: 404)
        }
        let antigravity = AntigravitySession(account: account(expiresIn: 3600), auth: auth(session)) { _ in }
        let transcriber = AntigravityTranscriber(session: antigravity, baseURL: Self.endpoints.api, urlSession: session,
                                                 version: AntigravityVersion(session: session))
        let text = try await transcriber.transcribe(audio, languages: ["tr", "en"], vocabulary: ["Computer Vision", ""])
        XCTAssertEqual(text, "Bugün geri yayılımı göreceğiz.")

        let sent = try XCTUnwrap(MockHTTP.requests.first { $0.request.url?.path == "/v1internal:generateContent" })
        XCTAssertEqual(sent.request.url?.absoluteString, "https://cloudcode.test/v1internal:generateContent")
        XCTAssertEqual(sent.header("Authorization"), "Bearer access-old")
        XCTAssertEqual(sent.header("User-Agent"), Self.userAgent)
        XCTAssertEqual(sent.header("Content-Type"), "application/json")
        XCTAssertEqual(sent.json["model"] as? String, "gemini-3-flash")
        XCTAssertEqual(sent.json["project"] as? String, "proj-1")
        XCTAssertEqual(sent.json["userAgent"] as? String, "antigravity")
        XCTAssertEqual(sent.json["requestType"] as? String, "agent")
        XCTAssertTrue((sent.json["requestId"] as? String)?.hasPrefix("agent-") == true)
        let request = try XCTUnwrap(sent.json["request"] as? [String: Any])
        XCTAssertTrue((request["sessionId"] as? String)?.hasPrefix("-") == true)
        XCTAssertNil(request["generationConfig"])
        let parts = try XCTUnwrap((request["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        let prompt = try XCTUnwrap(parts[0]["text"] as? String)
        XCTAssertTrue(prompt.contains("Languages spoken: tr, en."))
        XCTAssertTrue(prompt.contains("Names and terms to listen for: Computer Vision."))
        let inline = try XCTUnwrap(parts[1]["inlineData"] as? [String: Any])
        XCTAssertEqual(inline["mimeType"] as? String, "audio/mp4")
        XCTAssertEqual(inline["data"] as? String, Data([1, 2, 3, 4]).base64EncodedString())
        // the same prompt always gets the same session
        XCTAssertEqual(AntigravityTranscriber.sessionID(for: "a"), AntigravityTranscriber.sessionID(for: "a"))
        XCTAssertNotEqual(AntigravityTranscriber.sessionID(for: "a"), AntigravityTranscriber.sessionID(for: "b"))
    }

    func testTheTranscriberRenewsOnceWhenCloudCodeRejectsTheToken() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("piece-\(UUID().uuidString).m4a")
        try Data([0]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let counter = CodexAuthTests.Counter()
        let session = MockHTTP.session { recorded in
            switch recorded.request.url?.path {
            case "/v1internal:generateContent":
                if counter.next() == 0 { return .json(#"{"error":{"code":401,"message":"bad token","status":"UNAUTHENTICATED"}}"#, status: 401) }
                return .json(#"{"response":{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}}"#)
            case "/token":
                return .json(#"{"access_token":"access-new","expires_in":3599}"#)
            default:
                return .json("{}", status: 404)
            }
        }
        let antigravity = AntigravitySession(account: account(expiresIn: 3600), auth: auth(session)) { _ in }
        let transcriber = AntigravityTranscriber(session: antigravity, baseURL: Self.endpoints.api, urlSession: session,
                                                 version: AntigravityVersion(session: session))
        let text = try await transcriber.transcribe(audio, languages: [], vocabulary: [])
        XCTAssertEqual(text, "ok")
        let generates = MockHTTP.requests.filter { $0.request.url?.path == "/v1internal:generateContent" }
        XCTAssertEqual(generates.map { $0.header("Authorization") }, ["Bearer access-old", "Bearer access-new"])
    }
}

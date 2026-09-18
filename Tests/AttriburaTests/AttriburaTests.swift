import XCTest
@testable import Attribura

/// A URLProtocol that captures the outgoing request and returns a canned 200, so we can
/// assert what the SDK sends without touching the network.
final class MockURLProtocol: URLProtocol {
    static var onRequest: ((URLRequest) -> Void)?
    static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// `configure` reports an open by itself. Every test that is not about opens
    /// counts or captures "the request", so the open is answered and not announced.
    static var announcesOpens = false

    override func startLoading() {
        if MockURLProtocol.announcesOpens || request.url?.path != "/v1/ingest/app_open" {
            MockURLProtocol.onRequest?(Self.materialize(request))
        }
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: MockURLProtocol.statusCode,
                                       httpVersion: nil,
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves the body to `httpBodyStream`; read it back so tests can inspect it.
    private static func materialize(_ request: URLRequest) -> URLRequest {
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 4096
            var buffer = [UInt8](repeating: 0, count: size)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            req.httpBody = data
        }
        return req
    }
}

final class AttriburaTests: XCTestCase {

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// A directory per test, so the install id one test mints cannot be the id the
    /// next one reads back — the whole point of that file is that it survives.
    private var identityDir: URL!

    override func setUp() {
        super.setUp()
        // Every test in this process shares one on-disk queue, and a debounced
        // drain outlives the test that scheduled it. Start each one from empty.
        Attribura._setTestSession(nil)
        identityDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attribura-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: identityDir, withIntermediateDirectories: true)
        Attribura._identityDirectoryOverride = identityDir
    }

    override func tearDown() {
        MockURLProtocol.onRequest = nil
        MockURLProtocol.statusCode = 200
        MockURLProtocol.announcesOpens = false
        Attribura._setTestSession(nil)
        Attribura._identityDirectoryOverride = nil
        Attribura._installedAtOverride = nil
        if let dir = identityDir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    // MARK: - the anonymous id

    /// The id is the thread between an answer and a payment days later. If it moved
    /// between two reads, nothing in this product could be joined at all.
    func testTheAnonymousIdIsStableWithinALaunch() {
        let first = Attribura.anonymousId
        XCTAssertEqual(first, Attribura.anonymousId)
        XCTAssertNotNil(UUID(uuidString: first), "appAccountToken requires a UUID")
        XCTAssertEqual(Attribura.purchaseToken.uuidString, first)
    }

    /// And across launches, which is the case that actually matters: the answer is
    /// given on day one and the purchase lands on day three.
    func testTheAnonymousIdSurvivesARelaunch() {
        let first = Attribura.anonymousId

        // What a relaunch looks like from here: the memoised value is dropped, the
        // file is not.
        Attribura._setTestSession(nil)

        XCTAssertEqual(Attribura.anonymousId, first,
                       "a reinstall may mint a new id, a relaunch may not")
    }

    /// A fresh install is a new person, deliberately — nothing is resurrected from
    /// a Keychain that outlives the app.
    func testAFreshInstallMintsANewId() {
        let first = Attribura.anonymousId
        try? FileManager.default.removeItem(at: identityDir)
        try? FileManager.default.createDirectory(at: identityDir, withIntermediateDirectories: true)
        Attribura._setTestSession(nil)

        XCTAssertNotEqual(Attribura.anonymousId, first)
    }

    // MARK: - opens

    /// The whole retention feature from the app's side: configure, and nothing else.
    func testConfigureReportsTheOpenByItself() throws {
        Attribura._setTestSession(mockSession())
        MockURLProtocol.announcesOpens = true
        let installed = Date(timeIntervalSince1970: 1_780_000_000)
        Attribura._installedAtOverride = installed

        let exp = expectation(description: "app_open sent")
        var captured: URLRequest?
        MockURLProtocol.onRequest = { req in
            captured = req
            exp.fulfill()
        }
        Attribura.configure(token: "tok_test", baseURL: URL(string: "https://api.example.com")!,
                            userId: "user-7")
        wait(for: [exp], timeout: 5)

        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.path, "/v1/ingest/app_open")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Attribura-Token"), "tok_test")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["install_id"] as? String, Attribura.anonymousId,
                       "the cohort key is the id a purchase and an answer already carry")
        XCTAssertEqual(body?["installed_at"] as? String, ISO8601DateFormatter().string(from: installed))
        XCTAssertEqual(body?["user_id"] as? String, "user-7")
        XCTAssertEqual(body?["sdk_version"] as? String, Attribura.version)
        XCTAssertNotNil(body?["occurred_at"] as? String)
    }

    /// Retention asks "was this install here today", so the second open of a day —
    /// another call, a foreground, or a whole relaunch — sends nothing.
    func testAnOpenIsReportedOncePerDay() {
        Attribura._setTestSession(mockSession())
        MockURLProtocol.announcesOpens = true

        let first = expectation(description: "the day's first open")
        let again = expectation(description: "no second open")
        again.isInverted = true
        var seen = 0
        MockURLProtocol.onRequest = { _ in
            seen += 1
            if seen == 1 { first.fulfill() } else { again.fulfill() }
        }

        let base = URL(string: "https://api.example.com")!
        Attribura.configure(token: "tok_test", baseURL: base)
        Attribura.reportOpen()
        NotificationCenter.default.post(
            name: Notification.Name("UIApplicationDidBecomeActiveNotification"), object: nil)
        wait(for: [first], timeout: 5)

        // A relaunch: the memo is gone, the file beside the install id is not.
        let session = mockSession()
        Attribura._setTestSession(session)
        Attribura._identityDirectoryOverride = identityDir
        Attribura.configure(token: "tok_test", baseURL: base)
        wait(for: [again], timeout: 3)
    }

    /// A day spent offline is still a day the user came back: the open waits on
    /// disk and goes out at the next launch, carrying the day it happened.
    func testAnOpenRefusedByTheServerIsRetried() throws {
        Attribura._setTestSession(mockSession())
        MockURLProtocol.announcesOpens = true
        MockURLProtocol.statusCode = 503

        let failed = expectation(description: "first attempt refused")
        MockURLProtocol.onRequest = { _ in failed.fulfill() }
        let base = URL(string: "https://api.example.com")!
        Attribura.configure(token: "tok_test", baseURL: base)
        wait(for: [failed], timeout: 5)

        let queued = expectation(description: "the refused open reaches the queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { queued.fulfill() }
        wait(for: [queued], timeout: 2)

        MockURLProtocol.statusCode = 200
        let retried = expectation(description: "the open is sent again")
        var captured: URLRequest?
        MockURLProtocol.onRequest = { req in
            captured = req
            retried.fulfill()
        }
        Attribura.configure(token: "tok_test", baseURL: base)
        wait(for: [retried], timeout: 5)
        XCTAssertEqual(try XCTUnwrap(captured).url?.path, "/v1/ingest/app_open")
    }

    // MARK: - key actions

    /// Two actions a second apart are one request, a repeat of the same action in
    /// the same day is nothing, and the open tells the server what was declared.
    func testActionsAreSentOncePerDayInOneRequest() throws {
        Attribura._setTestSession(mockSession())
        MockURLProtocol.announcesOpens = true

        let sent = expectation(description: "open + one actions request")
        sent.expectedFulfillmentCount = 2
        var bodies: [String: [String: Any]] = [:]
        var requests = 0
        MockURLProtocol.onRequest = { req in
            requests += 1
            if let data = req.httpBody,
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                bodies[req.url?.path ?? ""] = body
            }
            sent.fulfill()
        }

        Attribura.configure(token: "tok_test", baseURL: URL(string: "https://api.example.com")!,
                            actions: ["meal_logged", "scan_done"])
        Attribura.action("meal_logged")
        Attribura.action("scan_done")
        Attribura.action("meal_logged")
        wait(for: [sent], timeout: 6)

        let quiet = expectation(description: "nothing else follows")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { quiet.fulfill() }
        wait(for: [quiet], timeout: 4)
        XCTAssertEqual(requests, 2)

        XCTAssertEqual(bodies["/v1/ingest/app_open"]?["actions"] as? [String],
                       ["meal_logged", "scan_done"])
        let batch = try XCTUnwrap(bodies["/v1/ingest/actions"])
        XCTAssertEqual(batch["install_id"] as? String, Attribura.anonymousId)
        XCTAssertEqual(batch["declared"] as? [String], ["meal_logged", "scan_done"])
        let names = (batch["actions"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["meal_logged", "scan_done"])
    }

    /// The queue file of 0.3.x has no `opens` key. It must still decode — what is
    /// waiting in it may be a sale.
    func testAQueueWrittenBeforeOpensExistedIsStillRead() throws {
        Attribura._setTestSession(mockSession())
        let dir = try XCTUnwrap(IngestClient._queueDirectoryOverride)
        let old = #"{"selfReports":[],"steps":[],"transactions":["jws.old.sig"]}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("attribura-queue-v2.json"))

        let sent = expectation(description: "the old sale goes out")
        var captured: URLRequest?
        MockURLProtocol.onRequest = { req in
            captured = req
            sent.fulfill()
        }
        Attribura.configure(token: "tok_test", baseURL: URL(string: "https://api.example.com")!)
        wait(for: [sent], timeout: 5)

        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.path, "/v1/ingest/storekit")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["signed_transactions"] as? [String], ["jws.old.sig"])
    }

    // MARK: - purchases

    func testTransactionsArePostedVerbatim() throws {
        Attribura._setTestSession(mockSession())

        let exp = expectation(description: "storekit request sent")
        var captured: URLRequest?
        MockURLProtocol.onRequest = { req in
            captured = req
            exp.fulfill()
        }

        Attribura.configure(token: "tok_test", baseURL: URL(string: "https://api.example.com")!)
        Attribura._reportTransactionsForTesting(["jws.one.sig", "jws.two.sig"])

        wait(for: [exp], timeout: 2)

        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.path, "/v1/ingest/storekit")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Attribura-Token"), "tok_test")

        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["signed_transactions"] as? [String], ["jws.one.sig", "jws.two.sig"],
                       "the receipt must reach the server exactly as Apple signed it")
    }

    /// A sale lost to a dead network is a sale lost for good on a consumable —
    /// StoreKit announces those once. So a 5xx has to leave it on disk.
    func testAFailedSaleIsRetriedOnTheNextFlush() throws {
        Attribura._setTestSession(mockSession())
        MockURLProtocol.statusCode = 503

        let failed = expectation(description: "first attempt refused")
        MockURLProtocol.onRequest = { _ in failed.fulfill() }

        Attribura.configure(token: "tok_test", baseURL: URL(string: "https://api.example.com")!)
        Attribura._reportTransactionsForTesting(["jws.kept.sig"])
        wait(for: [failed], timeout: 2)

        // The mock announces the REQUEST; the 503 lands after it, and only then is
        // the sale written to disk. Flushing before that would be a race the test
        // would lose about half the time — and would prove nothing when it won.
        let queued = expectation(description: "the refused sale reaches the queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { queued.fulfill() }
        wait(for: [queued], timeout: 2)

        // The next launch: the server is back.
        MockURLProtocol.statusCode = 200
        let retried = expectation(description: "the sale is sent again")
        var captured: URLRequest?
        MockURLProtocol.onRequest = { req in
            captured = req
            retried.fulfill()
        }
        Attribura.configure(token: "tok_test", baseURL: URL(string: "https://api.example.com")!)
        wait(for: [retried], timeout: 3)

        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.path, "/v1/ingest/storekit")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["signed_transactions"] as? [String], ["jws.kept.sig"])
    }

    func testReportSourcePostsExpectedRequest() throws {
        Attribura._setTestSession(mockSession())

        let exp = expectation(description: "self_report request sent")
        var captured: URLRequest?
        MockURLProtocol.onRequest = { req in
            captured = req
            exp.fulfill()
        }

        Attribura.configure(token: "tok_test", baseURL: URL(string: "https://api.example.com")!)
        Attribura.reportSource(.instagram, userId: "user-1", prompt: "How did you hear about us?")

        wait(for: [exp], timeout: 2)

        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.path, "/v1/ingest/self_report")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Attribura-Token"), "tok_test")

        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["source"] as? String, "instagram")
        XCTAssertEqual(body?["user_id"] as? String, "user-1")
        XCTAssertEqual(body?["platform"] as? String, "ios")
        XCTAssertEqual(body?["prompt"] as? String, "How did you hear about us?")
        XCTAssertNotNil(body?["occurred_at"] as? String)
    }

    func testReportSourceCarriesARunId() throws {
        Attribura._setTestSession(mockSession())

        let exp = expectation(description: "self_report carries run_id")
        var captured: URLRequest?
        MockURLProtocol.onRequest = { req in
            captured = req
            exp.fulfill()
        }

        Attribura.configure(token: "tok_test", baseURL: URL(string: "https://api.example.com")!)
        Attribura.reportSource(.instagram, userId: "user-1")

        wait(for: [exp], timeout: 2)
        let body = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(captured?.httpBody)) as? [String: Any]
        // The run id is what joins the answer to the onboarding funnel; without it
        // the funnel cannot be split by channel at all.
        let run = try XCTUnwrap(body?["run_id"] as? String)
        XCTAssertNotNil(UUID(uuidString: run))
    }

    /// The whole point of the batching: several steps leave as ONE request, and the
    /// run they belong to is the same one the self-report carries.
    func testStepsAreCoalescedIntoOneRequest() throws {
        Attribura._setTestSession(mockSession())

        let exp = expectation(description: "one steps request")
        var stepRequests: [URLRequest] = []
        MockURLProtocol.onRequest = { req in
            guard req.url?.path == "/v1/ingest/steps" else { return }
            stepRequests.append(req)
            exp.fulfill()
        }

        Attribura.configure(token: "tok_test",
                            baseURL: URL(string: "https://api.example.com")!,
                            onboarding: ["welcome", "goal", "source"])
        Attribura.step("welcome")
        Attribura.step("goal")

        wait(for: [exp], timeout: 6)

        XCTAssertEqual(stepRequests.count, 1, "steps must coalesce into a single request")
        let body = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(stepRequests.first?.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["onboarding"] as? [String], ["welcome", "goal", "source"])
        XCTAssertEqual(body?["platform"] as? String, "ios")
        let steps = try XCTUnwrap(body?["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.map { $0["step"] as? String }, ["welcome", "goal"])
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(body?["run_id"] as? String)))
    }

    /// A new run must be a different run — otherwise a second onboarding pass is
    /// swallowed by the server's per-run dedupe.
    func testNewRunChangesTheRunId() throws {
        Attribura._setTestSession(mockSession())

        let exp = expectation(description: "two self_report requests")
        exp.expectedFulfillmentCount = 2
        var bodies: [[String: Any]] = []
        MockURLProtocol.onRequest = { req in
            guard req.url?.path == "/v1/ingest/self_report",
                  let data = req.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            bodies.append(json)
            exp.fulfill()
        }

        Attribura.configure(token: "tok_test", baseURL: URL(string: "https://api.example.com")!)
        Attribura.reportSource(.instagram)
        Attribura.newRun()
        Attribura.reportSource(.tiktok)

        wait(for: [exp], timeout: 4)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertNotEqual(bodies[0]["run_id"] as? String, bodies[1]["run_id"] as? String)
    }

    /// The frontier of the channel split is whatever this field says. Inferring it
    /// from timestamps put it on the wrong step in production, which is why the
    /// answer names its own step.
    func testReportSourceNamesTheStepItWasGivenOn() throws {
        Attribura._setTestSession(mockSession())

        let exp = expectation(description: "self_report names at_step")
        var captured: [String: Any]?
        MockURLProtocol.onRequest = { req in
            guard req.url?.path == "/v1/ingest/self_report",
                  let data = req.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            captured = json
            exp.fulfill()
        }

        Attribura.configure(token: "tok_test",
                            baseURL: URL(string: "https://api.example.com")!,
                            onboarding: ["welcome", "goal", "source"])
        Attribura.step("welcome")
        Attribura.step("source")
        Attribura.reportSource(.tiktok)

        wait(for: [exp], timeout: 4)
        XCTAssertEqual(captured?["at_step"] as? String, "source")
    }

    func testDarkSocialSourceWireValue() {
        XCTAssertEqual(AttributionSource.friend.wireValue, "friend")
        XCTAssertEqual(AttributionSource.appStoreSearch.wireValue, "app_store_search")
        XCTAssertEqual(AttributionSource.googleSearch.wireValue, "google_search")
        XCTAssertEqual(AttributionSource.other("Some Newsletter").wireValue, "Some Newsletter")
    }

    func testDefaultUserIdIsUsedWhenOmitted() throws {
        Attribura._setTestSession(mockSession())

        let exp = expectation(description: "request uses default user id")
        var captured: URLRequest?
        MockURLProtocol.onRequest = { req in
            captured = req
            exp.fulfill()
        }

        Attribura.configure(token: "tok_test",
                            baseURL: URL(string: "https://api.example.com")!,
                            userId: "default-user")
        Attribura.reportSource(.tiktok)

        wait(for: [exp], timeout: 2)

        let body = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(captured?.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["source"] as? String, "tiktok")
        XCTAssertEqual(body?["user_id"] as? String, "default-user")
    }

    /// An app with no accounts passes no id at all. The answer must then carry the
    /// install id, because that is what `purchaseToken` gives Apple — otherwise the
    /// sale arrives with a key no answer was ever filed under.
    func testTheInstallIdIsUsedWhenTheAppHasNoUserId() throws {
        Attribura._setTestSession(mockSession())

        let exp = expectation(description: "request uses the install id")
        var captured: URLRequest?
        MockURLProtocol.onRequest = { req in
            captured = req
            exp.fulfill()
        }

        Attribura.configure(token: "tok_test",
                            baseURL: URL(string: "https://api.example.com")!)
        Attribura.reportSource(.tiktok)

        wait(for: [exp], timeout: 2)

        let body = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(captured?.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["user_id"] as? String, Attribura.purchaseToken.uuidString)
    }
}

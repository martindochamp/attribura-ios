import XCTest
@testable import Attribura

/// A URLProtocol that captures the outgoing request and returns a canned 200, so we can
/// assert what the SDK sends without touching the network.
final class MockURLProtocol: URLProtocol {
    static var onRequest: ((URLRequest) -> Void)?
    static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.onRequest?(Self.materialize(request))
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

    override func tearDown() {
        MockURLProtocol.onRequest = nil
        MockURLProtocol.statusCode = 200
        Attribura._setTestSession(nil)
        super.tearDown()
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
}

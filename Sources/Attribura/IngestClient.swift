import Foundation

/// Internal transport: builds and sends the self-report POST, with a tiny on-disk retry
/// queue so an event survives a flaky network or an app kill. Fire-and-forget — callers
/// never see errors; a failed send is buffered and retried on the next `flush()`
/// (which the SDK calls on `configure`, i.e. next launch).
final class IngestClient {
    /// The wire body for `POST /v1/ingest/self_report`. Optional fields are omitted when
    /// nil (Swift's synthesized Codable uses `encodeIfPresent`), matching the backend's
    /// `SelfReportIn`.
    struct Event: Codable {
        let source: String
        let user_id: String?
        let prompt: String?
        let occurred_at: String?
        let platform: String
        let sdk_version: String
        let context: [String: String]?
    }

    private let token: String
    private let endpoint: URL
    private let session: URLSession
    private let queueURL: URL
    private let ioQueue = DispatchQueue(label: "com.attribura.sdk.io")
    /// Cap the on-disk buffer so a long offline stretch can't grow it without bound.
    private let maxQueued = 100

    init(token: String, baseURL: URL, session: URLSession) {
        self.token = token
        self.endpoint = baseURL.appendingPathComponent("v1/ingest/self_report")
        self.session = session
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.queueURL = dir.appendingPathComponent("attribura-selfreport-queue.json")
    }

    /// Send an event now; buffer it for retry if the request fails.
    func send(_ event: Event) {
        post(event) { [weak self] ok in
            if !ok { self?.enqueue(event) }
        }
    }

    /// Retry everything buffered from a previous launch/failure. Safe to call anytime.
    func flush() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let pending = self.loadQueue()
            guard !pending.isEmpty else { return }
            self.saveQueue([])                    // optimistic clear; failures re-enqueue
            for event in pending { self.send(event) }
        }
    }

    // MARK: - transport

    private func post(_ event: Event, completion: @escaping (Bool) -> Void) {
        guard let body = try? JSONEncoder().encode(event) else {
            completion(false)
            return
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Attribura-Token")
        req.httpBody = body
        session.dataTask(with: req) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Retry on transport error or 5xx; a 4xx is a bad request that won't fix itself.
            let ok = error == nil && (200..<300).contains(code)
            let retryable = error != nil || (500..<600).contains(code)
            completion(ok || !retryable)          // treat non-retryable 4xx as "done"
        }.resume()
    }

    // MARK: - persistent queue

    private func enqueue(_ event: Event) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            var q = self.loadQueue()
            q.append(event)
            if q.count > self.maxQueued { q.removeFirst(q.count - self.maxQueued) }
            self.saveQueue(q)
        }
    }

    private func loadQueue() -> [Event] {
        guard let data = try? Data(contentsOf: queueURL),
              let q = try? JSONDecoder().decode([Event].self, from: data) else { return [] }
        return q
    }

    private func saveQueue(_ q: [Event]) {
        if q.isEmpty {
            try? FileManager.default.removeItem(at: queueURL)
            return
        }
        if let data = try? JSONEncoder().encode(q) {
            try? data.write(to: queueURL, options: .atomic)
        }
    }
}

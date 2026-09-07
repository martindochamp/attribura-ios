import Foundation

/// Internal transport: builds and sends the ingest POSTs, with a small on-disk retry
/// queue so nothing is lost to a flaky network or an app kill. Fire-and-forget —
/// callers never see errors; a failed send is buffered and retried on the next
/// `flush()` (which the SDK calls on `configure`, i.e. next launch).
final class IngestClient {

    // MARK: - wire types

    /// The body for `POST /v1/ingest/self_report`. Optional fields are omitted when
    /// nil (Swift's synthesized Codable uses `encodeIfPresent`), matching the
    /// backend's `SelfReportIn`.
    struct Event: Codable {
        let source: String
        let user_id: String?
        let prompt: String?
        let occurred_at: String?
        let platform: String
        let sdk_version: String
        let context: [String: String]?
        /// The onboarding run this answer was given in. This is what lets the
        /// funnel be split by channel: the answer and the steps share a run, so
        /// the join never has to wait for the app to know a user id.
        let run_id: String?
        /// The step the answer was given on — the last one `step(_:)` fired.
        /// Named rather than left to be inferred from timestamps, which slides to
        /// the wrong step whenever two of them land close together.
        let at_step: String?
    }

    /// One step inside a batch.
    struct Step: Codable {
        let step: String
        let occurred_at: String?
    }

    /// The body for `POST /v1/ingest/steps` — always one run per request.
    struct StepBatch: Codable {
        let run_id: String
        let onboarding: [String]
        var user_id: String?
        let platform: String
        let sdk_version: String
        var steps: [Step]
    }

    /// Transactions exactly as StoreKit handed them over, verified server-side
    /// against Apple's root before they become revenue. The SDK deliberately does
    /// NOT check `VerificationResult` itself and forwards the JWS whatever it
    /// says: a client that decides for itself which receipts are real is a client
    /// whose word we would have to take.
    struct TransactionBatch: Codable {
        let signed_transactions: [String]
    }

    /// What survives a launch. Typed lists rather than one opaque blob, because
    /// flushing has to MERGE step batches (see `flush`) and cannot do that to bytes.
    private struct Queue: Codable {
        var selfReports: [Event] = []
        var steps: [StepBatch] = []
        /// Sales that have not reached the server yet. Kept because a consumable
        /// is announced ONCE — unlike a subscription, StoreKit will not replay it
        /// at the next launch, so a request lost to a dead network loses the sale
        /// permanently unless it is on disk.
        var transactions: [String] = []
    }

    // MARK: - state

    private let token: String
    private let baseURL: URL
    private let session: URLSession
    private let queueURL: URL
    /// The 0.1.0 queue file, drained once on upgrade so a self-report buffered by
    /// the old version is not silently dropped when the format changes.
    private let legacyQueueURL: URL
    private let ioQueue = DispatchQueue(label: "com.attribura.sdk.io")
    /// Cap the on-disk buffer so a long offline stretch can't grow it without bound.
    private let maxQueued = 100
    /// Steps arrive seconds apart. Coalescing them into one request per short window
    /// is the difference between one radio wake and eight.
    private let batchWindow: TimeInterval = 2.0
    private var flushScheduled = false

    init(token: String, baseURL: URL, session: URLSession) {
        self.token = token
        self.baseURL = baseURL
        self.session = session
        let dir = IngestClient.queueDirectory()
        self.queueURL = dir.appendingPathComponent("attribura-queue-v2.json")
        self.legacyQueueURL = dir.appendingPathComponent("attribura-selfreport-queue.json")
    }

    /// Where the retry queue lives. The caches directory in an app — which is
    /// per-app and private, so the fixed filename is never contended.
    ///
    /// Tests override it. Two checkouts of this package running `swift test` at
    /// once are two processes sharing ONE developer caches directory, and a
    /// debounced drain from either will happily flush the other's queue: a real
    /// flake, seen once, and invisible in an app.
    private static func queueDirectory() -> URL {
        if let override = _queueDirectoryOverride { return override }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// Test-only. Set through `Attribura._setTestSession`.
    static var _queueDirectoryOverride: URL?

    // MARK: - sending

    /// Send a self-report now; buffer it for retry if the request fails.
    func send(_ event: Event) {
        post("v1/ingest/self_report", event) { [weak self] ok in
            guard let self = self, !ok else { return }
            self.mutateQueue { q in
                q.selfReports.append(event)
                if q.selfReports.count > self.maxQueued {
                    q.selfReports.removeFirst(q.selfReports.count - self.maxQueued)
                }
            }
        }
    }

    /// Send purchases now; buffer them for retry if the request fails.
    ///
    /// Batched rather than one request per transaction: an app coming back online
    /// after a week of offline renewals has a handful, and they belong in one
    /// round trip.
    func sendTransactions(_ jws: [String]) {
        guard !jws.isEmpty else { return }
        post("v1/ingest/storekit", TransactionBatch(signed_transactions: jws)) { [weak self] ok in
            guard let self = self, !ok else { return }
            self.mutateQueue { q in
                q.transactions.append(contentsOf: jws)
                if q.transactions.count > self.maxQueued {
                    q.transactions.removeFirst(q.transactions.count - self.maxQueued)
                }
            }
        }
    }

    /// Record one onboarding step.
    ///
    /// Persisted FIRST, sent on a short debounce. That order is deliberate: if the
    /// app is killed seconds after a step, the step is still on disk and goes out on
    /// the next launch. Buffering in memory instead would systematically lose the
    /// last step of every abandoned run — which is precisely the step a drop-off
    /// funnel exists to show.
    func enqueueStep(_ batch: StepBatch) {
        mutateQueue { q in
            q.steps.append(batch)
            if q.steps.count > self.maxQueued {
                q.steps.removeFirst(q.steps.count - self.maxQueued)
            }
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        ioQueue.async { [weak self] in
            guard let self = self, !self.flushScheduled else { return }
            self.flushScheduled = true
            self.ioQueue.asyncAfter(deadline: .now() + self.batchWindow) { [weak self] in
                guard let self = self else { return }
                self.flushScheduled = false
                self.drain()
            }
        }
    }

    /// Retry everything buffered from a previous launch/failure. Safe to call anytime.
    func flush() {
        ioQueue.async { [weak self] in self?.drain() }
    }

    /// Take everything off the queue and send it: self-reports one by one, step
    /// batches MERGED PER RUN so eight steps become one request. Anything that fails
    /// is re-queued by its own send path.
    private func drain() {
        let pending = loadQueue()
        guard !pending.selfReports.isEmpty || !pending.steps.isEmpty
                || !pending.transactions.isEmpty else { return }
        saveQueue(Queue())                       // optimistic clear; failures re-enqueue

        for event in pending.selfReports { send(event) }
        sendTransactions(pending.transactions)

        // Merge by run: same run, one request. Order is preserved so the oldest
        // run goes out first.
        var order: [String] = []
        var merged: [String: StepBatch] = [:]
        for batch in pending.steps {
            if var existing = merged[batch.run_id] {
                existing.steps.append(contentsOf: batch.steps)
                // A run that signs in mid-way carries its id on the later batches;
                // the newest non-nil wins so the whole run gets backfilled.
                if let uid = batch.user_id, !uid.isEmpty { existing.user_id = uid }
                merged[batch.run_id] = existing
            } else {
                order.append(batch.run_id)
                merged[batch.run_id] = batch
            }
        }

        for runId in order {
            guard let batch = merged[runId] else { continue }
            post("v1/ingest/steps", batch) { [weak self] ok in
                guard let self = self, !ok else { return }
                self.mutateQueue { q in
                    q.steps.append(batch)
                    if q.steps.count > self.maxQueued {
                        q.steps.removeFirst(q.steps.count - self.maxQueued)
                    }
                }
            }
        }
    }

    // MARK: - transport

    private func post<T: Encodable>(_ path: String,
                                    _ body: T,
                                    completion: @escaping (Bool) -> Void) {
        guard let encoded = try? JSONEncoder().encode(body) else {
            completion(true)                     // unencodable: retrying cannot help
            return
        }
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Attribura-Token")
        req.httpBody = encoded
        session.dataTask(with: req) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Retry on transport error or 5xx; a 4xx is a bad request that won't fix itself.
            let ok = error == nil && (200..<300).contains(code)
            let retryable = error != nil || (500..<600).contains(code)
            completion(ok || !retryable)         // treat non-retryable 4xx as "done"
        }.resume()
    }

    /// Delete the on-disk queue. Internal — the test target only.
    ///
    /// The queue is a fixed path in the caches directory, so every test in one
    /// process shares it, and a debounced drain scheduled by one test will happily
    /// flush whatever the next one has enqueued. Harmless in an app (the server
    /// merges by run and drops duplicates), fatal to a test that counts requests.
    static func _clearQueuesForTesting() {
        // A fresh directory per test: nothing to clear, and nothing another
        // process can reach into.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attribura-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _queueDirectoryOverride = dir
    }

    // MARK: - persistent queue

    private func mutateQueue(_ change: @escaping (inout Queue) -> Void) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            var q = self.loadQueue()
            change(&q)
            self.saveQueue(q)
        }
    }

    private func loadQueue() -> Queue {
        var q = Queue()
        if let data = try? Data(contentsOf: queueURL),
           let decoded = try? JSONDecoder().decode(Queue.self, from: data) {
            q = decoded
        }
        // One-time upgrade from the 0.1.0 format: a flat array of self-reports.
        if let legacy = try? Data(contentsOf: legacyQueueURL) {
            if let old = try? JSONDecoder().decode([Event].self, from: legacy) {
                q.selfReports.append(contentsOf: old)
            }
            try? FileManager.default.removeItem(at: legacyQueueURL)
        }
        return q
    }

    private func saveQueue(_ q: Queue) {
        // Every list, not just the two that existed first: a queue holding only a
        // refused SALE looked empty here and had its file deleted, which threw the
        // sale away. Caught by testAFailedSaleIsRetriedOnTheNextFlush.
        if q.selfReports.isEmpty && q.steps.isEmpty && q.transactions.isEmpty {
            try? FileManager.default.removeItem(at: queueURL)
            return
        }
        if let data = try? JSONEncoder().encode(q) {
            try? data.write(to: queueURL, options: .atomic)
        }
    }
}

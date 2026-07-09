import Foundation

/// Attribura SDK — headless self-report attribution.
///
/// The SDK does exactly one thing: it reports where a user says they heard about you
/// (your in-app "How did you hear about us?" answer) back to Attribura, which correlates
/// it with the content you posted. **It ships no UI** — you build the onboarding step /
/// bottom sheet, and call `reportSource` when the user picks an answer.
///
/// ```swift
/// // once, at app launch:
/// Attribura.configure(token: "<your ingest token>",
///                     baseURL: URL(string: "https://api.attribura.com")!)
///
/// // when the user taps an answer in your sheet:
/// Attribura.reportSource(.instagram, userId: currentUserId)
/// ```
///
/// The `token` is your org's Attribura ingest token — the same one the Superwall/Stripe
/// webhooks use — from **Settings → Integrations → Attribura SDK** in the dashboard.
public enum Attribura {
    /// SDK version, sent with every event (for support/debugging).
    public static let version = "0.1.0"

    private static let lock = NSLock()
    private static var client: IngestClient?
    private static var defaultUserId: String?
    private static var sessionOverride: URLSession?

    /// Configure the SDK once, as early as possible (e.g. in `application(_:didFinishLaunching…)`
    /// or your App's `init`). Passing `userId` here lets later `reportSource` calls omit it.
    /// Calling `configure` also flushes any events buffered from a previous launch.
    public static func configure(token: String, baseURL: URL, userId: String? = nil) {
        lock.lock()
        let session = sessionOverride ?? .shared
        let client = IngestClient(token: token, baseURL: baseURL, session: session)
        self.client = client
        self.defaultUserId = userId
        lock.unlock()
        client.flush()
    }

    /// Set (or update) the user id used when a `reportSource` call doesn't pass one —
    /// e.g. once you know the user's id after sign-in. Use the SAME id your revenue
    /// provider reports (Superwall's `app_user_id`), so the purchase can inherit the
    /// self-reported channel.
    public static func setUserId(_ userId: String?) {
        lock.lock()
        defaultUserId = userId
        lock.unlock()
    }

    /// Report where a user heard about you. Fire-and-forget and thread-safe — safe to
    /// call straight from a button tap on the main thread. No-op (with an assertion in
    /// debug builds) if called before `configure`.
    ///
    /// - Parameters:
    ///   - source: the answer the user selected.
    ///   - userId: the app user id; falls back to the id given to `configure`/`setUserId`.
    ///   - prompt: the exact question you showed, kept for auditing (optional).
    ///   - context: any extra key/values you want stored (locale, app version, …).
    public static func reportSource(_ source: AttributionSource,
                                    userId: String? = nil,
                                    prompt: String? = nil,
                                    context: [String: String]? = nil) {
        lock.lock()
        let client = self.client
        let uid = userId ?? defaultUserId
        lock.unlock()

        guard let client = client else {
            assertionFailure("Attribura.reportSource called before Attribura.configure(token:baseURL:)")
            return
        }

        let event = IngestClient.Event(
            source: source.wireValue,
            user_id: uid,
            prompt: prompt,
            occurred_at: ISO8601DateFormatter().string(from: Date()),
            platform: "ios",
            sdk_version: version,
            context: context
        )
        client.send(event)
    }

    // MARK: - Testing seam

    /// Inject a `URLSession` (e.g. backed by a mock `URLProtocol`) before `configure`.
    /// Internal — used by the test target only.
    static func _setTestSession(_ session: URLSession?) {
        lock.lock()
        sessionOverride = session
        lock.unlock()
    }
}

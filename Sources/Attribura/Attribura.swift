import Foundation

/// Attribura SDK — headless self-report attribution, and the onboarding funnel that
/// hangs off it.
///
/// The SDK does two things, both headless: it reports where a user says they heard
/// about you (your in-app *"How did you hear about us?"* answer), and — optionally —
/// which onboarding steps each run reached. **It ships no UI.**
///
/// The second is only interesting because of the first. An onboarding funnel on its
/// own is a commodity; this one is joined to the channel the same run self-reported,
/// so the dashboard can say *"TikTok installs drop at the notification step, Instagram
/// installs don't"* — which no general analytics tool can see.
///
/// ```swift
/// // once, at app launch:
/// Attribura.configure(token: "<your ingest token>",
///                     baseURL: URL(string: "https://api.attribura.com")!,
///                     onboarding: ["welcome", "goal", "source", "notifications", "paywall"])
///
/// // at the top of each onboarding screen:
/// Attribura.step("goal")
///
/// // when the user taps an answer in your sheet:
/// Attribura.reportSource(.instagram, userId: currentUserId)
/// ```
///
/// The `token` is your org's Attribura ingest token — the same one the Superwall/Stripe
/// webhooks use — from **Settings → Integrations → Attribura SDK** in the dashboard.
public enum Attribura {
    /// SDK version, sent with every event (for support/debugging).
    public static let version = "0.3.0"

    static let lock = NSLock()
    static var client: IngestClient?
    /// Memoised so the id file is read once per launch rather than per purchase.
    static var _anonymousId: String?
    /// Test-only: where the install id is written. See `Purchases.swift`.
    static var _identityDirectoryOverride: URL?
    private static var defaultUserId: String?
    private static var sessionOverride: URLSession?
    /// The ordered step names this app declared. The server resolves each step's
    /// position from this list, so it is the single source of funnel order.
    private static var onboarding: [String] = []
    /// The current onboarding run.
    ///
    /// Minted lazily, held **in memory only**, and deliberately not persisted. An
    /// onboarding run lasts minutes and never spans a relaunch; a run cut short by
    /// the app being killed *did* drop, and resuming it into the same run would hide
    /// a real abandonment. Keeping it out of `UserDefaults` also keeps the SDK clear
    /// of Apple's required-reason APIs, which is why `PrivacyInfo.xcprivacy` can
    /// declare an empty accessed-API list.
    private static var runId: String?
    /// The running purchase observer, or nil. Held so `observePurchases()` is
    /// idempotent — an app that calls it from both `init` and `onAppear` must not
    /// end up reporting every sale twice.
    static var purchaseTask: Task<Void, Never>?
    /// The last step `step(_:)` fired. `reportSource` sends it so the dashboard
    /// knows exactly where in the flow the question sits — everything from that
    /// step down can be split by channel, everything above it cannot.
    private static var lastStep: String?

    /// Configure the SDK once, as early as possible (e.g. in `application(_:didFinishLaunching…)`
    /// or your App's `init`). Passing `userId` here lets later calls omit it.
    /// Calling `configure` also flushes any events buffered from a previous launch.
    ///
    /// - Parameter onboarding: your onboarding step names, **in the order they
    ///   appear**. Declaring the shape here rather than in a dashboard means the
    ///   order is authoritative and a step nobody reaches shows a real zero instead
    ///   of vanishing from the funnel. Omit it if you are not tracking steps.
    public static func configure(token: String,
                                 baseURL: URL,
                                 userId: String? = nil,
                                 onboarding: [String] = []) {
        lock.lock()
        let session = sessionOverride ?? .shared
        let client = IngestClient(token: token, baseURL: baseURL, session: session)
        self.client = client
        self.defaultUserId = userId
        self.onboarding = onboarding
        lock.unlock()
        client.flush()
    }

    /// Set (or update) the user id used when a call doesn't pass one — e.g. once you
    /// know the user's id after sign-in. Use the SAME id your revenue provider
    /// reports (Superwall's `app_user_id`), so the purchase can inherit the
    /// self-reported channel.
    ///
    /// Calling this mid-onboarding is worth doing: the id is attached to the whole
    /// run server-side, so steps already recorded before sign-in are backfilled and
    /// the run can still be followed into trial and paid.
    public static func setUserId(_ userId: String?) {
        lock.lock()
        defaultUserId = userId
        let client = self.client
        let run = runId
        let steps = onboarding
        lock.unlock()

        // Send an empty batch purely to carry the id backwards over the run. Cheap,
        // and it is what turns an anonymous run into one with a revenue tail.
        guard let client = client, let run = run, let userId = userId, !userId.isEmpty,
              !steps.isEmpty else { return }
        client.enqueueStep(IngestClient.StepBatch(
            run_id: run,
            onboarding: steps,
            user_id: userId,
            platform: "ios",
            sdk_version: version,
            steps: []
        ))
    }

    /// Report that this run reached an onboarding step.
    ///
    /// Fire-and-forget and thread-safe — call it from `onAppear` / `viewDidAppear` of
    /// each onboarding screen. The name must be one you passed to
    /// `configure(onboarding:)`; anything else is reported back as *undeclared* so a
    /// typo shows up in the integration rather than as a funnel row that looks wrong
    /// weeks later.
    ///
    /// Steps are written to disk immediately and sent coalesced a couple of seconds
    /// later, so an app killed mid-onboarding still reports every step it reached.
    public static func step(_ name: String) {
        lock.lock()
        let client = self.client
        let steps = onboarding
        let uid = defaultUserId
        if runId == nil { runId = UUID().uuidString }
        let run = runId!
        lastStep = name
        lock.unlock()

        guard let client = client else {
            assertionFailure("Attribura.step called before Attribura.configure(token:baseURL:)")
            return
        }
        guard !steps.isEmpty else {
            assertionFailure("Attribura.step called without declaring configure(onboarding:)")
            return
        }

        client.enqueueStep(IngestClient.StepBatch(
            run_id: run,
            onboarding: steps,
            user_id: uid,
            platform: "ios",
            sdk_version: version,
            steps: [IngestClient.Step(step: name, occurred_at: iso8601(Date()))]
        ))
    }

    /// Start a NEW onboarding run.
    ///
    /// Only needed when one app session can onboard twice — a sign-out that returns
    /// the user to the start, or a "redo the setup" path. Without it the second pass
    /// reuses the first run, and because a run records each step once, the repeated
    /// steps are correctly ignored — which would quietly hide the second attempt.
    public static func newRun() {
        lock.lock()
        runId = UUID().uuidString
        lastStep = nil
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
        // The answer joins the funnel through the run, so a run is minted here too
        // when `step` was never called — harmless for apps that only self-report.
        if runId == nil { runId = UUID().uuidString }
        let run = runId
        let atStep = lastStep
        lock.unlock()

        guard let client = client else {
            assertionFailure("Attribura.reportSource called before Attribura.configure(token:baseURL:)")
            return
        }

        let event = IngestClient.Event(
            source: source.wireValue,
            user_id: uid,
            prompt: prompt,
            occurred_at: iso8601(Date()),
            platform: "ios",
            sdk_version: version,
            context: context,
            run_id: run,
            at_step: atStep
        )
        client.send(event)
    }

    // MARK: - internals

    /// One formatter per call is wasteful, but `ISO8601DateFormatter` is not
    /// documented as thread-safe and these calls come off arbitrary threads.
    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Testing seam

    /// Inject a `URLSession` (e.g. backed by a mock `URLProtocol`) before `configure`.
    /// Internal — used by the test target only.
    static func _setTestSession(_ session: URLSession?) {
        lock.lock()
        sessionOverride = session
        runId = nil
        lastStep = nil
        onboarding = []
        _anonymousId = nil
        lock.unlock()
        IngestClient._clearQueuesForTesting()
    }
}

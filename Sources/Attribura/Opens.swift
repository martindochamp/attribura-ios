import Foundation

// MARK: - Retention

extension Attribura {
    /// The last UTC day an open was recorded, memoised from its file.
    static var _lastOpenDay: String?
    /// Test-only: stands in for the container's creation date.
    static var _installedAtOverride: Date?
    private static var foregroundObserver: NSObjectProtocol?

    /// Report that this install opened the app today.
    ///
    /// **You do not need to call this.** `configure` calls it, and the SDK calls
    /// it again each time the app returns to the foreground, so an app that is
    /// never killed still reports the days it was used. It is public for the one
    /// case the SDK cannot see: a platform with no foreground notification.
    ///
    /// # What it is for
    ///
    /// App Store Connect has no retention by cohort — no D1, no D7, no device id
    /// in any report. Whether an install comes back is only knowable from inside
    /// the app, and this is the whole of it: the install id, and today.
    ///
    /// # Once per day, decided here
    ///
    /// A retention curve asks "was this install here on day N", never "how many
    /// times". So the first call of a UTC day sends, and every later one returns
    /// before touching the network or the disk. The day is kept in a file beside
    /// the install id — not `UserDefaults`, for the same reason the id is not.
    public static func reportOpen() {
        let now = Date()
        let today = String(iso8601(now).prefix(10))   // ISO8601DateFormatter is UTC
        // Read before taking the lock: `anonymousId` takes it too.
        let installId = anonymousId

        lock.lock()
        let client = self.client
        let uid = defaultUserId
        if _lastOpenDay == nil {
            _lastOpenDay = (try? String(contentsOf: identityFile("last-open-day"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // No client means nothing was recorded, so the day is not spent.
        let alreadyReported = _lastOpenDay == today
        if client != nil && !alreadyReported { _lastOpenDay = today }
        lock.unlock()

        guard let client = client else {
            assertionFailure("Attribura.reportOpen called before Attribura.configure(token:baseURL:)")
            return
        }
        guard !alreadyReported else { return }

        // Best effort. A write that fails costs one duplicate tomorrow morning,
        // which the server counts once anyway.
        try? today.data(using: .utf8)?.write(to: identityFile("last-open-day"), options: .atomic)

        client.enqueueOpen(IngestClient.Open(
            install_id: installId,
            occurred_at: iso8601(now),
            installed_at: installedAt().map(iso8601),
            user_id: uid,
            app_version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            platform: "ios",
            sdk_version: version
        ))
    }

    /// When the app was installed: the creation date of its data container.
    ///
    /// The install id cannot answer this — it is minted the first time the SDK
    /// runs, and for an install that predates the SDK that is the day of the
    /// UPDATE. Without the real date, every existing user would join the cohort of
    /// the day they updated and, being the ones who stayed, make it the best
    /// cohort the app ever had.
    ///
    /// This is the SDK's one required-reason API (file timestamp, reason C617.1:
    /// a file inside the app's own container), declared in `PrivacyInfo.xcprivacy`.
    private static func installedAt() -> Date? {
        if let override = _installedAtOverride { return override }
        guard let library = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: library.path)
        return attributes?[.creationDate] as? Date
    }

    /// Report an open each time the app comes back to the foreground.
    ///
    /// By name, so the SDK stays Foundation-only: importing UIKit to spell
    /// `UIApplication.didBecomeActiveNotification` would cost the platforms that
    /// have no `UIApplication`. Where nobody posts it, nothing happens.
    static func observeForeground() {
        lock.lock()
        defer { lock.unlock() }
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidBecomeActiveNotification"),
            object: nil,
            queue: nil
        ) { _ in reportOpen() }
    }
}

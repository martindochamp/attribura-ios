import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

// MARK: - The anonymous id

extension Attribura {
    /// A stable id for this install, with no account and no permission prompt.
    ///
    /// # Why this exists at all
    ///
    /// The product's whole claim is that a post can be tied to a payment. Those are
    /// two events days apart, and something has to say they belong to the same
    /// person. On iOS, without an account, that something is an id the app carries
    /// itself.
    ///
    /// # Why a generated UUID rather than `identifierForVendor`
    ///
    /// Three reasons, in order of weight:
    ///
    ///   1. **The privacy manifest.** IDFV is a device identifier, and collecting
    ///      one obliges every app that embeds this SDK to declare "Device ID" in
    ///      its App Store nutrition label. A UUID this SDK mints is a user id — a
    ///      category already declared, and one every app declares anyway. The cost
    ///      of a field is not storage, it is what we make our customers sign.
    ///   2. **`appAccountToken` wants a UUID** and this is one by construction.
    ///   3. **Foundation only.** IDFV would drag in UIKit and with it the platforms
    ///      that have no `UIDevice`.
    ///
    /// # Where it is kept, and why not the Keychain
    ///
    /// A plain file, alongside the retry queue. The Keychain would survive
    /// deletion of the app — which is exactly the "persistent identifier" Apple
    /// treats as tracking in disguise, and it fails review. So a reinstall is a new
    /// person here. That loses a little continuity and keeps the SDK honest, and
    /// file I/O adds nothing to `PrivacyInfo.xcprivacy`: no required-reason API is
    /// touched (`UserDefaults` is one, which is the other reason this is a file).
    public static var anonymousId: String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = _anonymousId { return cached }

        let url = anonymousIdURL()
        if let data = try? Data(contentsOf: url),
           let existing = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           UUID(uuidString: existing) != nil {
            _anonymousId = existing
            return existing
        }

        let minted = UUID().uuidString
        // Best effort. A write that fails means a new id next launch — a lost
        // join, never a crash, and never a reason to hold up an app's launch.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? minted.data(using: .utf8)?.write(to: url, options: .atomic)
        _anonymousId = minted
        return minted
    }

    /// [`anonymousId`] as a `UUID`, to hand to StoreKit.
    ///
    /// ```swift
    /// try await product.purchase(options: [.appAccountToken(Attribura.purchaseToken)])
    /// ```
    ///
    /// **This one line is what makes the whole chain work.** Apple stores the token
    /// on the transaction and signs it, so the purchase arrives already carrying the
    /// id that answered "how did you hear about us". Skip it and the sale is still
    /// recorded — it is simply nobody's, and no post can be credited for it.
    public static var purchaseToken: UUID {
        UUID(uuidString: anonymousId) ?? UUID()
    }

    /// Application Support rather than Caches: the system may evict a caches
    /// directory whenever it likes, and an id that disappears under memory pressure
    /// would silently split one person into several.
    private static func anonymousIdURL() -> URL {
        if let override = _identityDirectoryOverride {
            return override.appendingPathComponent("attribura-install-id")
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Attribura", isDirectory: true)
            .appendingPathComponent("install-id")
    }
}

// MARK: - Purchases

#if canImport(StoreKit)
@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
extension Attribura {
    /// Start reporting purchases. Call once, right after `configure`.
    ///
    /// ```swift
    /// Attribura.configure(token: "…", baseURL: URL(string: "https://api.attribura.com")!)
    /// Attribura.observePurchases()
    /// ```
    ///
    /// # What it sends, and what it does not
    ///
    /// Every transaction StoreKit reports, forwarded **verbatim** — the JWS Apple
    /// signed, nothing added, nothing interpreted. The server checks that signature
    /// against Apple's root before a cent is booked, which is why this SDK does not
    /// bother inspecting `VerificationResult` first: a receipt this app judged for
    /// itself would still have to be judged again.
    ///
    /// It reports two streams. `currentEntitlements` catches up on what the person
    /// already owns — the install that bought before the SDK existed, or before the
    /// network came back. `updates` is everything from now on, including renewals
    /// and refunds Apple issues while the app is closed, which arrive at the next
    /// launch.
    ///
    /// # It never calls `finish()`
    ///
    /// Finishing a transaction is the app saying "I have delivered what was
    /// bought". Only the app knows that. An SDK that finished transactions on your
    /// behalf would tell Apple the goods were handed over before your code ran —
    /// so this one reads and reports, and leaves delivery entirely alone.
    public static func observePurchases() {
        lock.lock()
        let alreadyRunning = purchaseTask != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let task = Task.detached(priority: .background) {
            // The catch-up pass first, so a purchase made before this launch is
            // reported before anything new lands on top of it.
            var owned: [String] = []
            for await result in Transaction.currentEntitlements {
                owned.append(result.jwsRepresentation)
            }
            report(owned)

            for await result in Transaction.updates {
                report([result.jwsRepresentation])
            }
        }

        lock.lock()
        purchaseTask = task
        lock.unlock()
    }

    /// Stop reporting. Only the test target needs this — an app observes for its
    /// whole life, because a subscription can renew at any moment it is running.
    static func stopObservingPurchases() {
        lock.lock()
        let task = purchaseTask
        purchaseTask = nil
        lock.unlock()
        task?.cancel()
    }

    /// Test-only. Feeds the reporting path without a StoreKit transaction, which
    /// no unit test can conjure — a real one is signed by Apple.
    static func _reportTransactionsForTesting(_ jws: [String]) {
        report(jws)
    }

    /// Deliberately NOT `async`. Taking an `NSLock` across a suspension point is
    /// an error in Swift 6, and there is nothing to await here: reading the client
    /// is a lock, and sending is fire-and-forget on `URLSession`.
    private static func report(_ jws: [String]) {
        guard !jws.isEmpty else { return }
        lock.lock()
        let client = self.client
        lock.unlock()
        client?.sendTransactions(jws)
    }
}
#endif

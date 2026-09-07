# Attribura iOS SDK

Headless **self-report attribution** for iOS, plus the **onboarding funnel** that hangs
off it. It reports where a user says they heard about you (your in-app *"How did you
hear about us?"* answer) back to Attribura, which correlates it with the content you
posted — including the **dark social** and **App Store Search** traffic no tracking link
can ever see.

Optionally it also reports which onboarding steps each run reached. That second part is
only interesting because of the first: an onboarding funnel on its own is a commodity,
but this one is joined to the channel the same run self-reported — so your dashboard can
say *"TikTok installs drop at the notification step, Instagram installs don't."*

- **No UI.** You build the onboarding step / bottom sheet; the SDK just does the tracking.
- **No third-party dependencies.** Just `Foundation`/`URLSession`.
- **Fire-and-forget.** Failed sends are buffered on disk and retried on next launch.

## Install (Swift Package Manager)

In Xcode: **File → Add Package Dependencies…** and paste
`https://github.com/martindochamp/attribura-ios`, or add it to your `Package.swift`:

```swift
.package(url: "https://github.com/martindochamp/attribura-ios", from: "0.3.0")
```

## Setup

Get your **ingest token** from the Attribura dashboard: **Settings → Integrations →
Attribura SDK** (it's the same per-org token the Superwall/Stripe webhooks use).

```swift
import Attribura

// Once, as early as possible — e.g. in your App's init or didFinishLaunching:
Attribura.configure(
    token: "atb_ingest_xxx",
    baseURL: URL(string: "https://api.attribura.com")!,
    // Optional: your onboarding screens, in order. Only needed for the funnel.
    onboarding: ["welcome", "goal", "source", "notifications", "paywall"]
)
```

## Report the answer

Call `reportSource` when the user picks an answer in **your own** sheet. Use the same
user id your revenue provider reports (Superwall's `app_user_id`) so the eventual
purchase inherits the self-reported channel:

```swift
Attribura.reportSource(.instagram, userId: currentUserId)
```

### Example: a SwiftUI "How did you hear about us?" sheet

The SDK ships no UI — here's a minimal sheet you own and wire up yourself:

```swift
import SwiftUI
import Attribura

struct HeardAboutUsSheet: View {
    let userId: String
    var onDone: () -> Void

    private let options: [(String, AttributionSource)] = [
        ("Instagram",       .instagram),
        ("TikTok",          .tiktok),
        ("YouTube",         .youtube),
        ("A friend",        .friend),
        ("A podcast",       .podcast),
        ("App Store search",.appStoreSearch),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How did you hear about us?").font(.title3.bold())
            ForEach(options, id: \.0) { label, source in
                Button(label) {
                    Attribura.reportSource(source, userId: userId, prompt: "How did you hear about us?")
                    onDone()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}
```

## Track the onboarding funnel (optional)

Declare your screens once, in order, at `configure`. Then call `step` at the top of each
one:

```swift
struct GoalScreen: View {
    var body: some View {
        content.onAppear { Attribura.step("goal") }
    }
}
```

That is the whole API. A few things worth knowing:

- **The order lives in your code, not in a dashboard.** The list you pass to `configure`
  is the funnel. Change it and Attribura treats it as a new funnel version rather than
  rewriting your history.
- **A name you did not declare is reported back as `undeclared`**, so a typo shows up in
  the integration instead of as a funnel row that looks wrong weeks later.
- **Steps hit disk before they hit the network**, then leave coalesced a couple of
  seconds later. An app killed mid-onboarding still reports every step it reached.
- **Call `setUserId` as soon as you know who the user is.** It attaches the id to the
  whole run, including the steps recorded before sign-in — which is what lets the funnel
  carry on into trial and paid.
- **Call `Attribura.newRun()`** only if one app session can onboard twice (a sign-out
  that returns to the start). Each run records a step once, so without it the second pass
  is ignored.

### Put the question early

Your funnel can only be split by channel from the step where the question is answered
downwards. A run that quits before it never reported a channel, so those earlier steps
show a total and no breakdown. Moving *"How did you hear about us?"* one screen earlier
lights up one more step — the dashboard shows you how many are still dark. The trade is
real in the other direction too: asked on screen one, a question costs some completion.
Somewhere after one cheap commitment and before your first real ask is the sweet spot.

## Sources

`instagram` · `tiktok` · `youtube` · `x` · `reddit` · `linkedin` · `threads` ·
`facebook` · `googleSearch` · `appStoreSearch` · `friend` · `podcast` · `newsletter` ·
`other("…")` for anything else (free-text "Other").

The linkable channels (Instagram, TikTok, …) are cross-checked against your recent
certified-link posts — a single recent post on that channel lets Attribura name the
exact content. The rest are captured as **dark social**. Attribution is always
confidence-scored, never sold as deterministic.

## Report the money (recommended)

Two lines, and no configuration in App Store Connect at all.

```swift
// once, right after configure:
Attribura.observePurchases()

// and on every purchase, so the sale knows whose it is:
try await product.purchase(options: [.appAccountToken(Attribura.purchaseToken)])
```

The second line is the one that matters. Apple stores that token on the transaction
and signs it, so a purchase arrives already carrying the id that answered *"how did
you hear about us"* — which is what lets the dashboard say a post earned $12 instead
of just showing you $12.

Every transaction is forwarded **exactly as Apple signed it** and verified server-side
against Apple's own root certificate before a cent is booked. The SDK never calls
`finish()` on your transactions: only your app knows when it has delivered what was
bought.

Without `appAccountToken` the sale is still recorded — it simply belongs to nobody,
and no post can be credited for it.

**Sandbox purchases are welcome.** They are real signatures on fake money, stored
apart so no total counts them, which is how you prove the whole chain works before
you ship.

**What this replaces:** nothing else is needed for iAP revenue — no Superwall, no
RevenueCat, no App Store Server Notifications url (Apple allows only one per app, and
your customer may already be using it).

## How it fits

```
User taps "Instagram"  ──►  Attribura.reportSource(.instagram, userId:)
                                     │  POST /v1/ingest/self_report
                                     ▼
     stored as a touchpoint keyed by userId ──► when that user's purchase lands, the
     revenue inherits the self-reported channel (and, when a single recent Instagram
     post exists, the exact post).
```

The purchase reaches the same key straight from Apple, with nobody in between:

```
product.purchase(options: [.appAccountToken(Attribura.purchaseToken)])
                                     │  Apple signs the transaction, token included
                                     ▼
Attribura.observePurchases()  ──►  POST /v1/ingest/storekit
                                     │  signature checked against Apple Root CA - G3
                                     ▼
        the amount joins the self-report on that same id, and the post gets credited
```

With steps declared, the same run carries the funnel:

```
Attribura.step("welcome") ─┐
Attribura.step("goal")     ├─► POST /v1/ingest/steps   (one request per run)
Attribura.step("source")   ─┘        │
                                     ▼
    the run's steps + the run's self-reported channel are the same run, so the
    dashboard draws the drop-off PER CHANNEL — and follows it into trial and paid
    through the user id you set.
```

## Privacy

Ships a **privacy manifest** (`PrivacyInfo.xcprivacy`): it declares a **User ID**, one
**Other** data type (the answer), **Product Interaction** (the onboarding step names you
declared) and **Purchase History** (the transactions Apple signed) — all *linked to the
user*, *not used for tracking*, purpose **Analytics**. The SDK does **not** track in
Apple's sense, so it needs **no ATT prompt**. Declare the same in your app's App Store
privacy label.

**No device or advertising identifiers are collected.** `Attribura.anonymousId` is a
UUID this SDK mints for the install — not `identifierForVendor`, precisely so that you
never have to declare a Device ID. It lives in a plain file in Application Support, so
deleting the app deletes it: a reinstall is a new person here, and nothing is
resurrected from a Keychain that outlives the app. The onboarding run id is held in
memory for the life of the process and never written to disk.

**Upgrading from 0.1.0:** `Product Interaction` is new. If you already shipped with this
SDK and you start calling `step`, add it to your app's privacy answers in App Store
Connect. Nothing else about the upgrade is breaking — `configure(onboarding:)` is
optional and every 0.1.0 call site keeps working unchanged.

## Testing

```
swift test
```

The tests use a mock `URLProtocol` — no network required.

# Attribura iOS SDK

Headless **self-report attribution** for iOS. One job: capture the answer to your
in-app *"How did you hear about us?"* question and send it to Attribura, which ties it
to the content you posted — including the **word-of-mouth** and **App Store Search**
traffic that no tracking link can ever see.

- 🪶 **Headless** — no UI. You build the sheet; the SDK just tracks.
- 📦 **Zero dependencies** — just `Foundation` / `URLSession`.
- 🔁 **Reliable** — fire-and-forget, with an on-disk retry queue so an answer survives a
  flaky network or an app kill.
- 🔒 **Safe** — one write-only ingest token; no user data read back, no PII required.

> Attribution is always **confidence-scored and directional**, never sold as
> deterministic. Self-report fills the gap deterministic links miss — it never overrides
> a certified link or discount code.

---

## Install

### Swift Package Manager (Xcode)

**File → Add Package Dependencies…**, then paste:

```
https://github.com/martindochamp/attribura-ios
```

Pick **Up to Next Major Version** from `0.1.0`.

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/martindochamp/attribura-ios", from: "0.1.0"),
],
targets: [
    .target(name: "YourApp", dependencies: ["Attribura"]),
]
```

---

## Quick start

Get your **ingest token** from the Attribura dashboard:
**Settings → Integrations → Attribura SDK** (it's the same per-org token the
Superwall/Stripe webhooks use).

```swift
import Attribura

// 1. Configure once, as early as possible (App init / didFinishLaunching):
Attribura.configure(
    token: "atb_ingest_xxx",
    baseURL: URL(string: "https://api.attribura.com")!
)

// 2. Report the answer when the user taps a choice in YOUR sheet:
Attribura.reportSource(.instagram, userId: currentUserId)
```

That's the whole API. Use the **same user id your revenue provider reports**
(Superwall's `app_user_id`) so the eventual purchase inherits the self-reported channel.

---

## The "How did you hear about us?" sheet

The SDK ships **no UI** — here's a minimal SwiftUI sheet you own and wire up yourself:

```swift
import SwiftUI
import Attribura

struct HeardAboutUsSheet: View {
    let userId: String
    var onDone: () -> Void

    private let options: [(String, AttributionSource)] = [
        ("Instagram",        .instagram),
        ("TikTok",           .tiktok),
        ("YouTube",          .youtube),
        ("A friend",         .friend),
        ("A podcast",        .podcast),
        ("App Store search", .appStoreSearch),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How did you hear about us?")
                .font(.title3.bold())
            ForEach(options, id: \.0) { label, source in
                Button(label) {
                    Attribura.reportSource(source,
                                           userId: userId,
                                           prompt: "How did you hear about us?")
                    onDone()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}
```

> **Tip — randomize the order.** People rushing onboarding tend to tap the same position
> every time (usually the first), which quietly biases your data. Shuffle the options per
> user with `options.shuffled()` so that noise averages out.

---

## API

### `Attribura.configure(token:baseURL:userId:)`

Call once, early. Passing `userId` here lets later `reportSource` calls omit it. Also
flushes any answers buffered from a previous launch.

### `Attribura.setUserId(_:)`

Set/update the default user id once you know it (e.g. after sign-in).

### `Attribura.reportSource(_:userId:prompt:context:)`

Report where a user heard about you. Fire-and-forget and thread-safe — call it straight
from a button tap on the main thread.

| Parameter | Type | Notes |
|---|---|---|
| `source` | `AttributionSource` | The answer selected. |
| `userId` | `String?` | App user id; falls back to `configure`/`setUserId`. |
| `prompt` | `String?` | The exact question shown (for auditing). |
| `context` | `[String: String]?` | Extra key/values (locale, app version, …). |

### `AttributionSource`

`.instagram` · `.tiktok` · `.youtube` · `.x` · `.reddit` · `.linkedin` · `.threads` ·
`.facebook` · `.googleSearch` · `.appStoreSearch` · `.friend` · `.podcast` ·
`.newsletter` · `.other("…")` for anything else (a free-text "Other" field).

The linkable channels (Instagram, TikTok, …) are cross-checked against your recent
certified-link posts — a single recent post on that channel lets Attribura name the
exact content. The rest are captured as **dark social**.

---

## How it works

```
User taps "Instagram"  ─►  Attribura.reportSource(.instagram, userId:)
                                   │  POST /v1/ingest/self_report
                                   ▼
   stored as a touchpoint keyed by userId ─► when that user's Superwall/Stripe
   purchase lands, the revenue inherits the self-reported channel (and, when a single
   recent Instagram post exists, the exact post).
```

Nothing sensitive leaves the device — just the answer, the user id you pass, a
timestamp, and the SDK version. The token is **write-only** (ingest); it can't read your
data back.

---

## Privacy

Ships a **privacy manifest** (`PrivacyInfo.xcprivacy`): it declares a **User ID** and one
**Other** data type (the answer), both *linked to the user*, *not used for tracking*,
purpose **Analytics**. The SDK does **not** track in Apple's sense, so it needs **no ATT
prompt**. Declare the same in your app's App Store privacy label. No device or advertising
identifiers are collected.

---

## Testing

```
swift test
```

The tests use a mock `URLProtocol` — no network required.

---

## Integrating with an AI assistant

Paste [`llms.txt`](./llms.txt) into Claude / ChatGPT and ask it to wire the SDK into your
app. It's a complete, self-contained integration guide.

---

## License

MIT

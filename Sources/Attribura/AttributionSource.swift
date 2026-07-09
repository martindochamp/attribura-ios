import Foundation

/// Where a user says they heard about you — the answer to your in-app
/// "How did you hear about us?" step. The cases mirror the channels Attribura can
/// carry a certified link on (instagram, tiktok, …) plus the "dark social" answers
/// no link can ever see (a friend, a podcast, App Store search).
///
/// The server normalizes the wire value, so `.other("Some Newsletter")` is fine for
/// anything not listed — it just lands in the dark-social bucket.
public enum AttributionSource: Equatable {
    case instagram
    case tiktok
    case youtube
    case x
    case reddit
    case linkedin
    case threads
    case facebook

    // Dark social — unlinkable, but the traffic every link misses.
    case googleSearch
    case appStoreSearch
    case friend
    case podcast
    case newsletter

    /// Any answer not covered above (e.g. a free-text "Other" field).
    case other(String)

    /// The string sent to the backend. Kept in sync with `attribution::normalize_source`.
    public var wireValue: String {
        switch self {
        case .instagram: return "instagram"
        case .tiktok: return "tiktok"
        case .youtube: return "youtube"
        case .x: return "x"
        case .reddit: return "reddit"
        case .linkedin: return "linkedin"
        case .threads: return "threads"
        case .facebook: return "facebook"
        case .googleSearch: return "google_search"
        case .appStoreSearch: return "app_store_search"
        case .friend: return "friend"
        case .podcast: return "podcast"
        case .newsletter: return "newsletter"
        case .other(let raw): return raw
        }
    }
}

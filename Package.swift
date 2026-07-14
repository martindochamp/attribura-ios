// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Attribura",
    // macOS is included so the package can `swift test` on a dev Mac; iOS is the target.
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [
        .library(name: "Attribura", targets: ["Attribura"]),
    ],
    targets: [
        // Zero third-party dependencies — just Foundation/URLSession.
        // The privacy manifest is bundled so Xcode aggregates it into the app's
        // App Store privacy report automatically.
        .target(
            name: "Attribura",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "AttriburaTests", dependencies: ["Attribura"]),
    ]
)

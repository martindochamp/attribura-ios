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
        .target(name: "Attribura"),
        .testTarget(name: "AttriburaTests", dependencies: ["Attribura"]),
    ]
)

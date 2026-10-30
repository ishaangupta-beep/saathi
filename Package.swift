// swift-tools-version: 6.2
//
// Builds Saathi with Apple's Command Line Tools only — no Xcode needed.
// Use ./build-saathi.sh, which compiles this package and wraps the
// result in Saathi.app. (Xcode users can keep using the .xcodeproj.)
//

import PackageDescription

let package = Package(
    name: "Saathi",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Saathi",
            path: "leanring-buddy",
            exclude: [
                "AGENTS.md",
                "Assets.xcassets",
                "Info.plist",
                "leanring-buddy.entitlements"
            ],
            swiftSettings: [
                // Match the Xcode project's settings so the code compiles the same way.
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
                .enableUpcomingFeature("DisableOutwardActorInference")
            ]
        )
    ]
)

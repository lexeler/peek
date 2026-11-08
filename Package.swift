// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Peek",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Peek",
            path: "Sources/Peek",
            swiftSettings: [
                // UI app: everything lives on the main actor unless explicitly marked `nonisolated`.
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreBluetooth"),
            ]
        )
    ]
)

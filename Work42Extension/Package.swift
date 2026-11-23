// swift-tools-version: 6.2

import PackageDescription

// Work42Extension is the third package root in the public work42-sdk repository (SDK 3.2.0): the runtime for a plugin
// that runs out of process, as an ExtensionKit extension in its own container app. The Work42 app links it too, for the
// wire and XPC protocols it speaks to such plugins.
//
// A separate package, not a target of Work42PluginKit, for the same reason Work42UI is separate from Work42PluginKit: a
// target that depends on an in-package target links it STATICALLY, so Work42PluginKit's code would be copied into
// Work42Extension.framework next to the app's own Work42PluginKit.framework (Xcode refuses the build: "linked as a static
// library ... but cannot be built dynamically because there is a package product with the same name"). Across packages,
// Work42PluginKit is the dynamic product, so exactly one runtime copy of each module exists in every process.
let concurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .defaultIsolation(MainActor.self),
    // Library evolution, as in the other two packages: the app ships the `.swiftinterface` that `work42 plugin build`
    // compiles extension plugins against.
    .unsafeFlags([
        "-enable-library-evolution", "-emit-module-interface", "-no-verify-emitted-module-interface",
    ]),
]

let package = Package(
    name: "Work42Extension",
    platforms: [
        .macOS(.v15),
        .iOS(.v26),
    ],
    products: [
        .library(name: "Work42Extension", type: .dynamic, targets: ["Work42Extension"]),
    ],
    dependencies: [
        .package(path: "../Work42PluginKit"),
        .package(path: "../Work42UI"),
    ],
    targets: [
        .target(
            // The JSON wire both sides speak, the XPC protocols, a proxy for every `SessionServices` member, the
            // dispatcher for host requests, and `Work42PluginExtension`, the protocol a plugin's `@main` extension type
            // conforms to. The wire and the proxies are plain Swift (unit-tested over an in-memory channel); the
            // ExtensionKit plumbing is macOS-only.
            name: "Work42Extension",
            // Work42UI is listed although Work42PluginKit re-exports it: the re-export is for the compiler, and the
            // framework still has to link Work42UI.framework itself for the symbols it uses (BrowserTab, the SDK version).
            dependencies: [
                .product(name: "Work42PluginKit", package: "Work42PluginKit"),
                .product(name: "Work42UI", package: "Work42UI"),
            ],
            path: "Sources/Work42Extension",
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "Work42ExtensionTests",
            dependencies: ["Work42Extension", .product(name: "Work42PluginKit", package: "Work42PluginKit")],
            path: "Tests/Work42ExtensionTests",
            swiftSettings: concurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

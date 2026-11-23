// swift-tools-version: 6.2

import PackageDescription

// Work42PluginKit is one of two package roots in the public work42-sdk repository.
//
// Two packages, not one: if WidgetKit and Work42UI were targets of a single
// sub-package, WidgetKit's in-package dependency on Work42UI would be linked
// STATICALLY into Work42PluginKit.framework (SwiftPM only honors dynamic
// products across package boundaries) — re-creating the duplicate-metadata
// problem between the two frameworks. As separate packages, WidgetKit links
// Work42UI as an external dynamic product, so at runtime exactly one copy of
// each module exists: the app, WidgetKit, and every hot-loaded widget dylib
// all resolve Work42UI through the one embedded Work42UI.framework.
let concurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .defaultIsolation(MainActor.self),
    // Library evolution emits a compiler-independent `.swiftinterface`, which
    // is what the app ships so plugins build with the app's Swift or newer.
    // Swift 6.3 omits `-default-isolation MainActor` from the interface header,
    // so the compiler's own re-verification of it fails; skip that step. The
    // release script patches the header and checks the shipped interface instead.
    .unsafeFlags([
        "-enable-library-evolution", "-emit-module-interface", "-no-verify-emitted-module-interface",
    ]),
]

let package = Package(
    name: "Work42PluginKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v26),
    ],
    products: [
        .library(name: "Work42PluginKit", type: .dynamic, targets: ["Work42PluginKit"]),
        // SDK 3.2.0: the runtime for a plugin that runs out of process, as an ExtensionKit extension inside its own
        // container app. The extension process links it; the Work42 app never does (it talks to it over XPC).
        .library(name: "Work42Extension", type: .dynamic, targets: ["Work42Extension"]),
    ],
    dependencies: [
        .package(path: "../Work42UI"),
    ],
    targets: [
        .target(
            // Everything an out-of-repo, agent-authored widget compiles
            // against: the `Work42Widget` protocol (identity + layouts + min
            // size + lifecycle + view factory), the XPC-shaped
            // `SessionServices` protocols (async-only, Codable payloads, no
            // app-internal types — so the later ExtensionKit move is a
            // transport swap, not an SDK redesign), the `work42_widget_main`
            // entry-point ABI + SDK version constant, and `BrowserSurface`
            // (the browser base component over the WebSection stack).
            // Depends ONLY on Work42UI (re-exported so widget code gets DT
            // tokens + components from a single import) — never on Work42App
            // or any app-shell module.
            name: "Work42PluginKit",
            dependencies: [
                .product(name: "Work42UI", package: "Work42UI"),
            ],
            path: "Sources/Work42PluginKit",
            swiftSettings: concurrencySettings
        ),
        .target(
            // The out-of-process plugin runtime (SDK 3.2.0): the JSON wire both sides speak, the XPC protocols, a proxy
            // for every `SessionServices` member, the dispatcher for host requests, and `Work42PluginExtension`, the
            // protocol a plugin's `@main` extension type conforms to. The wire and the proxies are plain Swift and run on
            // every platform (so they are unit-tested over an in-memory channel); the ExtensionKit plumbing is macOS-only.
            name: "Work42Extension",
            dependencies: ["Work42PluginKit"],
            path: "Sources/Work42Extension",
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "Work42ExtensionTests",
            dependencies: ["Work42Extension", "Work42PluginKit"],
            path: "Tests/Work42ExtensionTests",
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            // browser-widgets-not-extending-from-browser.2 — unit tests for
            // the rebuilt `BrowserSurfaceCache`: model-cache identity, teardown
            // releasing both model and per-tab live views, teardownAll prefix
            // scoping.  Pure / WebKit-free — no WKWebView is created.
            // Uses @testable import so internal helpers (existingModel(forKey:),
            // model(forKey:building:)) are accessible.
            name: "Work42PluginKitTests",
            dependencies: ["Work42PluginKit"],
            path: "Tests/Work42PluginKitTests",
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "Work42CompatibilityTests",
            dependencies: ["Work42PluginKit", .product(name: "Work42UI", package: "Work42UI")],
            path: "Tests/Work42CompatibilityTests",
            swiftSettings: concurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

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
]

let package = Package(
    name: "Work42PluginKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "Work42PluginKit", type: .dynamic, targets: ["Work42PluginKit"]),
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

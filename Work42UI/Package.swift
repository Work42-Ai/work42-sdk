// swift-tools-version: 6.2

import PackageDescription

// Work42UI is one of two package roots in the public work42-sdk repository.
//
// Why a separate package at all: SwiftPM ignores `.library(type: .dynamic)`
// for same-package consumers — an executable target in the same package
// always links its sibling targets STATICALLY, so the "framework" the old
// in-package product produced was an empty shell while the app carried a
// duplicate static copy of every Work42UI symbol. Only an EXTERNAL package
// dependency honors the dynamic product type. Moving the design system here
// makes `Work42UI.framework` real: the app, Work42PluginKit, and every
// hot-loaded custom widget link the ONE embedded copy via @rpath — which is
// the invariant that keeps Swift type metadata/conformances unique at
// runtime (two copies = the documented subtle-crash class).
let concurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "Work42UI",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "Work42UI", type: .dynamic, targets: ["Work42UI"]),
    ],
    dependencies: [
        // MarkdownUI + cmark link INTO Work42UI.framework and nowhere else.
        // Work42UI `@_exported import`s MarkdownUI (see ReExports.swift), so
        // app-side consumers (Flow42Core chat, Work42App) reach the API via
        // `import Work42UI` and resolve the symbols from this framework —
        // declaring MarkdownUI as a direct dependency of any main-package
        // target would statically link a SECOND copy into the app and
        // reintroduce the duplicate-metadata crash class one level down.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
        // cmark-gfm: markdown → GFM HTML for the WebView-based
        // MarkdownPreview (free-form selection/copy MarkdownUI can't do).
        .package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.7.1"),
        // Yams: YAML codec for ThemeYAML (theme-customization subtask .1,
        // carried into this sub-package by the feat/custom-widgets rebase).
        // The Theme module decodes/encodes YAML theme files without
        // dragging in Flow42Core's AX + recording stack.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            // Design system: tokens (spacing, radii, type scale, brand
            // palette), reusable components (Card and friends), the
            // Markdown theme, and the WebSection stack (WebSectionView /
            // WebSectionSpec / WebAppCatalog) every embedded-web widget
            // rides on. Stays free of AX / capture / YAML dependencies so
            // any surface can pull in the visual language without dragging
            // in Flow42Core's accessibility stack.
            name: "Work42UI",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/Work42UI",
            resources: [
                // mermaid.min.js — bundled so the canvas shell renders
                // mermaid diagrams with zero agent effort; loopback-only,
                // served from `_w42/mermaid.min.js` by the artifact server.
                .copy("Resources/mermaid.min.js"),
                // highlight.min.js — bundled syntax highlighter (highlight.js
                // v11 common build); served from `_w42/highlight.min.js`, themed
                // via CanvasTemplate.highlightCSS token mapping.
                .copy("Resources/highlight.min.js"),
                // w42-components.css — tokenized component library styled
                // via --w42-* custom props (light/dark + accent for free).
                .copy("Resources/w42-components.css"),
                // picker-core.js — transport-agnostic element-picker DOM
                // logic loaded into the WKWebView tiles.
                .copy("Resources/picker-core.js"),
            ],
            swiftSettings: concurrencySettings,
            // WebKit powers the reusable WebSectionView: a WKWebView that
            // renders a real web app cropped to one section by CSS selector.
            linkerSettings: [.linkedFramework("WebKit")]
        ),
    ],
    swiftLanguageModes: [.v6]
)

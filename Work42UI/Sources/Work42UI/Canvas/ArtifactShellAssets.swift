// ArtifactShellAssets.swift — Bundle accessors for the artifact shell assets
// shipped with Work42UI.
//
// The `ArtifactServer` (Work42App) serves two shell assets from the Work42UI
// bundle rather than the per-session artifact dir, because they are provided
// by the system shell, not by the agent:
//
//   _w42/mermaid.min.js   — the bundled mermaid v11 UMD library
//   _w42/w42-components.css — the tokenized component library CSS
//
// `CanvasTemplate.mermaidLibrary()` already exposes the mermaid bytes.
// This file adds the analogous accessor for the component CSS so the
// ArtifactServer can read it on the main actor at startup and cache the
// bytes for its off-main request path — exactly the same pattern.
//
// Both assets live in Work42UI's resource bundle; `Bundle.module` here
// refers to that bundle. The `@MainActor` annotation mirrors
// `CanvasTemplate.mermaidLibrary()` (Bundle.module is main-actor-isolated
// under this module's default isolation).

import Foundation

public enum ArtifactShellAssets {

    /// Relative URL path the artifact shell serves the component CSS from.
    ///
    /// Resolved against the artifact root (`/<sessionId>-<token>/<artifactId>/`),
    /// so the effective URL is `…/<artifactId>/_w42/w42-components.css`.
    /// Living under the same `_w42/` prefix as the mermaid asset and the
    /// error route keeps it namespaced away from agent-placed assets.
    public nonisolated static let componentCSSAssetPath = "_w42/w42-components.css"

    /// Reads the bundled component-library stylesheet from Work42UI's resource
    /// bundle. `nil` only if the resource is somehow missing from the build
    /// (the shell then degrades gracefully — the themed shell still renders).
    ///
    /// `Bundle.module` is `@MainActor`-isolated under this module's default
    /// isolation, so the read happens on the main actor; the artifact server
    /// calls this once at start and caches the bytes for its off-main request
    /// path (mirroring the `CanvasTemplate.mermaidLibrary()` pattern).
    @MainActor
    public static func componentCSSData() -> Data? {
        guard let url = Bundle.module.url(
            forResource: "w42-components", withExtension: "css"
        ) else { return nil }
        return try? Data(contentsOf: url)
    }
}

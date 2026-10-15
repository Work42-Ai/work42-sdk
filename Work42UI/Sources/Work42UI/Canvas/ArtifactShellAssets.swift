// ArtifactShellAssets.swift — Bundle accessors for the artifact shell assets
// shipped with Work42UI.
//
// The `ArtifactServer` (Work42App) serves two shell assets from the Work42UI
// bundle rather than the per-session artifact dir, because they are provided
// by the system shell, not by the agent:
//
//   _w42/mermaid.min.js   — the bundled mermaid v11 UMD library
//   _w42/w42-components.css — the tokenized component library CSS
//   _w42/w42-components.js  — the <w42-*> tag runtime
//   _w42/kit/<file>         — the Preline + Work42 kit (Resources/kit)
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

    /// URLs the legacy composition links its (frozen) component CSS / tag runtime from.
    /// They are served from `kit/legacy/`; the older `_w42/w42-components.*` paths below
    /// keep working and return the same bytes.
    public nonisolated static let legacyCSSAssetPath = "_w42/legacy/w42-components-v1.css"
    public nonisolated static let legacyJSAssetPath = "_w42/legacy/w42-components-v1.js"

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
        kitFileData("legacy/w42-components-v1.css")
    }

    /// Relative URL path the artifact shell serves the `<w42-*>` tag runtime from.
    public nonisolated static let componentJSAssetPath = "_w42/w42-components.js"

    /// Reads the bundled tag runtime (`w42-components.js`). Same lifecycle and
    /// isolation as ``componentCSSData()``.
    @MainActor
    public static func componentJSData() -> Data? {
        kitFileData("legacy/w42-components-v1.js")
    }

    // MARK: - Kit (Preline + Work42 theme)

    /// URL prefix the artifact shell serves the kit files from
    /// (`_w42/kit/<relative path inside Resources/kit>`).
    public nonisolated static let kitAssetPrefix = "_w42/kit/"

    /// The bundled kit directory (`Resources/kit`): Preline files, the Work42
    /// theme and recipes, `w42-kit.js`, the precompiled `w42-kit-full.css`, the
    /// gallery and the frozen `legacy/` copies. `nil` only if it is missing from
    /// the build.
    @MainActor
    public static func kitDirectoryURL() -> URL? {
        Bundle.module.url(forResource: "kit", withExtension: nil)
    }

    /// Reads one file from the bundled kit directory by its path relative to
    /// `Resources/kit` (e.g. `"w42-kit-full.css"`, `"preline/preline.js"`).
    /// Returns `nil` for a missing file or any path that would escape the kit
    /// directory. Same lifecycle and isolation as ``componentCSSData()``.
    @MainActor
    public static func kitFileData(_ relativePath: String) -> Data? {
        guard let dir = kitDirectoryURL(),
              let url = resolveKitFile(relativePath, in: dir) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Resolves `relativePath` inside `directory`, refusing anything that is
    /// empty, absolute, contains a `..` / backslash / NUL component, or that
    /// resolves (after symlinks) outside `directory`. Pure, so it is unit-tested
    /// without the bundle.
    public nonisolated static func resolveKitFile(_ relativePath: String, in directory: URL) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.contains("\0") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return nil }
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = base.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(base.path + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return candidate
    }

    /// Absolute path of the bundled Web Kit gallery fragment (`w42-gallery.html`),
    /// or `nil` if it is missing from the build. Printed by
    /// `work42 artifact gallery-path`.
    @MainActor
    public static func galleryPath() -> String? {
        Bundle.module.url(forResource: "w42-gallery", withExtension: "html")?.path
    }
}

// CanvasTemplate.swift - The built-in themed HTML shell for the agent canvas.
//
// The agent canvas (T-001) serves agent-authored HTML over a real
// `http://127.0.0.1` origin. The guiding principle is that the agent
// should only ever produce the *content* it wants shown — never the
// boilerplate. This file is that boilerplate: a complete, theme-matched
// HTML document wrapped around the agent's content fragment, plus an
// error-overlay layer so a broken script is visible inline instead of a
// blank page.
//
// The scaffold is intentionally implemented as **embedded Swift string
// constants** rather than SwiftPM resource files. That keeps composition
// pure, deterministic, unit-testable, and free of any `Bundle.module`
// lookup or `Package.swift` resource declaration.
//
// `compose(content:themeCSS:)` is `nonisolated` pure string work: it
// takes the already-generated theme CSS as input (so it never has to call
// the `@MainActor CanvasTheme.legacyCSS()` itself) and can be invoked freely
// from the canvas server off the main actor.

import Foundation

public enum CanvasTemplate {

    /// Relative path the error overlay POSTs captured runtime errors to.
    ///
    /// Resolved against the canvas root (`/<session-id>-<token>/`), so the
    /// effective URL is `…/<session-id>-<token>/_w42/error`. The
    /// `CanvasServer` mounts a matching route there and appends each JSON
    /// body to the session's `errors.jsonl`.
    public nonisolated static let errorReportPath = "_w42/error"

    /// Relative path the shell loads the bundled mermaid library from.
    ///
    /// Resolved against the canvas root (`/<session-id>-<token>/`), so the
    /// effective URL is `…/<session-id>-<token>/_w42/mermaid.min.js`. This
    /// is a **shell** asset — it ships with `Work42UI` (NOT the per-session
    /// canvas dir), so `CanvasServer` serves it from `Bundle.module` ahead
    /// of the per-session asset lookup. Living under the same `_w42/` prefix
    /// as the error route keeps it namespaced away from agent assets.
    public nonisolated static let mermaidAssetPath = "_w42/mermaid.min.js"

    /// Relative path the shell loads the bundled highlight.js library from
    /// (mirrors `mermaidAssetPath`). Effective URL:
    /// `…/<session-id>-<token>/_w42/highlight.min.js`. A shell asset — it ships
    /// with `Work42UI`, served from `Bundle.module` under the `_w42/` prefix.
    public nonisolated static let highlightAssetPath = "_w42/highlight.min.js"

    /// Reads the bundled mermaid v11 UMD library from `Work42UI`'s resource
    /// bundle. `nil` only if the resource is somehow missing from the build
    /// (the shell then degrades to plain text rather than throwing).
    ///
    /// `Bundle.module` is `@MainActor`-isolated under this module's default
    /// isolation, so the read happens on the main actor; the canvas server
    /// calls this once at start and caches the bytes for its off-main
    /// request path (mirroring how it caches `CanvasTheme.legacyCSS()`).
    @MainActor
    public static func mermaidLibrary() -> Data? {
        guard let url = Bundle.module.url(
            forResource: "mermaid.min", withExtension: "js"
        ) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The component library stylesheet (`w42-components.css`) as a string, for
    /// callers that must INLINE it rather than link `_w42/w42-components.css`
    /// (which only the ArtifactServer serves). Used by the spec/markdown
    /// document template so spec-embedded HTML (trailing components, raw HTML)
    /// can use the same `.w42-*` classes as artifacts. Empty string if the
    /// resource is missing from the build (degrades gracefully).
    /// Reads the bundled highlight.js v11 library from `Work42UI`'s resource
    /// bundle (mirrors `mermaidLibrary()`). `nil` if missing from the build.
    @MainActor
    public static func highlightLibrary() -> Data? {
        guard let url = Bundle.module.url(
            forResource: "highlight.min", withExtension: "js"
        ) else { return nil }
        return try? Data(contentsOf: url)
    }

    @MainActor
    public static func componentLibraryCSS() -> String {
        guard let data = ArtifactShellAssets.kitFileData("legacy/w42-components-v1.css"),
              let css = String(data: data, encoding: .utf8) else { return "" }
        return css
    }

    /// The bundled `<w42-*>` tag runtime (`w42-components.js`), for surfaces that
    /// inline it (markdown documents) instead of loading `_w42/w42-components.js`.
    @MainActor
    public static func componentLibraryJS() -> String {
        guard let data = ArtifactShellAssets.kitFileData("legacy/w42-components-v1.js"),
              let js = String(data: data, encoding: .utf8) else { return "" }
        return js
    }

    /// JS that auto-renders mermaid diagrams in the canvas with zero effort
    /// from the agent.
    ///
    /// Authors deliver mermaid either as `<pre class="mermaid">…graph…</pre>`
    /// (the natural raw-HTML form for a canvas fragment) or as a fenced
    /// ```` ```mermaid ```` block that some markdown renderer turned into
    /// `<pre><code class="language-mermaid">…</code></pre>`. This script
    /// normalizes the fenced form into `<pre class="mermaid">`, then loads
    /// the bundled library and runs mermaid over the collected nodes.
    ///
    /// It is a strict no-op when the page has no mermaid nodes (the library
    /// is never even loaded), and every step is guarded so a render failure
    /// surfaces in the error overlay without taking down the rest of the
    /// canvas. Theme follows the OS appearance (`dark` under
    /// `prefers-color-scheme: dark`). Self-guarded against double-install so
    /// it is safe in both composed and full-document modes.
    /// The mermaid auto-render script, parameterized by the URL the bundled
    /// library is served from. The Canvas serves it over its loopback HTTP
    /// server (`mermaidAssetPath`, the default); the Markdown WebView serves it
    /// via a custom `WKURLSchemeHandler` — both call this ONE function so the
    /// render logic can never drift between the two surfaces.
    public nonisolated static func mermaidJS(src: String = mermaidAssetPath) -> String {
    """
    (function () {
      "use strict";
      if (window.__w42MermaidInstalled) { return; }
      window.__w42MermaidInstalled = true;

      var SRC = "\(src)";

      // Normalize a fenced ```mermaid``` block (rendered by a markdown
      // pass as <pre><code class="language-mermaid">) into the
      // <pre class="mermaid"> shape mermaid.run() expects. Returns the
      // count of mermaid nodes present after normalization.
      function collect() {
        try {
          var fenced = document.querySelectorAll(
            "pre > code.language-mermaid, pre > code.lang-mermaid"
          );
          for (var i = 0; i < fenced.length; i++) {
            var code = fenced[i];
            var pre = code.parentElement;
            if (!pre) { continue; }
            var graph = code.textContent || "";
            var node = document.createElement("pre");
            node.className = "mermaid";
            node.textContent = graph;
            pre.parentNode.replaceChild(node, pre);
          }
        } catch (e) { /* fall through — count whatever is present */ }
        // Stash each diagram's ORIGINAL graph source before mermaid replaces the
        // node's textContent with a colour-baked SVG. rerender() restores from
        // this so a live theme change can re-run mermaid against the new palette.
        var present = document.querySelectorAll("pre.mermaid, .mermaid");
        for (var k = 0; k < present.length; k++) {
          if (present[k].getAttribute("data-w42-src") == null) {
            present[k].setAttribute("data-w42-src", present[k].textContent || "");
          }
        }
        return present.length;
      }

      function run() {
        var count = collect();
        // No mermaid on the page → never load the 3MB library.
        if (count === 0) { return; }

        function render() {
          if (!window.mermaid || typeof window.mermaid.run !== "function") {
            return;
          }
          try {
            // Read --w42-* CSS custom properties so mermaid uses the app
            // palette in both light and dark mode. theme:"base" lets us
            // supply all key colours via themeVariables; getComputedStyle
            // reads the already-injected CanvasTheme <style> block so light
            // vs dark is resolved by the browser before we pass values in.
            var cs = window.getComputedStyle
              ? getComputedStyle(document.documentElement) : null;
            function tv(n) {
              if (!cs) { return undefined; }
              var v = cs.getPropertyValue(n);
              return (v && v.trim()) ? v.trim() : undefined;
            }
            window.mermaid.initialize({
              startOnLoad: false,
              securityLevel: "strict",
              theme: "base",
              // Nodes sit on the ELEVATED surface (the refined look); accent is
              // reserved for borders + arrowheads, never fills. The .w42-mermaid
              // svg CSS in diagramControlsCSS layers rounding, a soft shadow,
              // tinted clusters, and pill edge-labels on top — all --w42-* driven.
              fontFamily: tv("--w42-font-family"),
              themeVariables: {
                background:          tv("--w42-backdrop"),
                mainBkg:             tv("--w42-elevated"),
                primaryColor:        tv("--w42-elevated"),
                primaryTextColor:    tv("--w42-text-primary"),
                primaryBorderColor:  tv("--w42-accent"),
                lineColor:           tv("--w42-text-tertiary"),
                secondaryColor:      tv("--w42-surface"),
                tertiaryColor:       tv("--w42-backdrop"),
                titleColor:          tv("--w42-text-primary"),
                edgeLabelBackground: tv("--w42-surface"),
                fontFamily:          tv("--w42-font-family"),
                clusterBkg:          tv("--w42-surface"),
                clusterBorder:       tv("--w42-accent")
              },
              // Smoother edges + more breathing room (the confirmed direction).
              flowchart: { curve: "basis", nodeSpacing: 54, rankSpacing: 62, useMaxWidth: true }
            });
            // run() returns a promise; surface async failures to the overlay.
            var p = window.mermaid.run({
              querySelector: "pre.mermaid, .mermaid"
            });
            if (p && typeof p.then === "function") {
              p.then(sweepMermaidErrors, function (err) {
                if (window.console && console.error) { console.error(err); }
                sweepMermaidErrors();
              });
            } else {
              setTimeout(sweepMermaidErrors, 50);
            }
          } catch (err) {
            if (window.console && console.error) { console.error(err); }
          }
        }

        // Mermaid sometimes renders an in-place "Syntax error" diagram instead
        // of rejecting run() — catch those mechanically so a broken diagram is
        // reported to errors.jsonl (validation, not by eye).
        function sweepMermaidErrors() {
          try {
            var nodes = document.querySelectorAll("pre.mermaid, .mermaid");
            for (var i = 0; i < nodes.length; i++) {
              var n = nodes[i];
              if (n.getAttribute("data-w42-err-reported")) { continue; }  // report once
              var bad = n.querySelector('[aria-roledescription="error"], .error-icon, .error-text');
              var txt = (n.textContent || "");
              if (bad || /Syntax error in text|Parse error|error hierarchy/i.test(txt)) {
                n.setAttribute("data-w42-err-reported", "1");
                if (window.console && console.error) {
                  console.error("w42 diagram error: mermaid failed to render \\u2014 "
                    + txt.slice(0, 200).replace(/\\s+/g, " ").trim());
                }
              }
            }
          } catch (e) {}
        }

        if (window.mermaid) { render(); return; }

        var s = document.createElement("script");
        s.src = SRC;
        s.onload = render;
        s.onerror = function () {
          if (window.console && console.error) {
            console.error("Failed to load bundled mermaid from " + SRC);
          }
        };
        (document.head || document.documentElement).appendChild(s);
      }

      // ---- Live re-theme entry point -------------------------------------
      // mermaid inlines resolved hex colours into the SVG at render time, so a
      // `:root` --w42-* variable swap (window.__w42.theme.apply) cannot recolour
      // an already-rendered diagram. To track the app theme we must RE-RUN
      // mermaid: restore each node's original graph source, clear mermaid's
      // data-processed marker, and run() again (which re-initializes
      // themeVariables from a fresh getComputedStyle read).
      var rerunning = false;
      function resetForRerender() {
        var nodes = document.querySelectorAll("pre.mermaid, .mermaid");
        for (var i = 0; i < nodes.length; i++) {
          var n = nodes[i];
          var src = n.getAttribute("data-w42-src");
          if (src != null) { n.textContent = src; }   // drop baked SVG, restore graph
          n.removeAttribute("data-processed");         // let mermaid.run reprocess
          n.removeAttribute("data-w42-err-reported");  // allow error re-report
        }
      }
      function rerender() {
        if (rerunning) { return; }                     // guard concurrent re-runs
        if (!window.mermaid) { return; }               // nothing rendered yet → nothing to re-bake
        rerunning = true;
        try { resetForRerender(); run(); }
        finally { setTimeout(function () { rerunning = false; }, 0); }
      }
      window.__w42 = window.__w42 || {};
      window.__w42.mermaid = { rerender: rerender };

      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", run);
      } else {
        run();
      }
    })();
    """
    }

    /// The **shared prose stylesheet** — the single source of truth for the
    /// RHYTHM of markdown-to-HTML text: body 15px / 1.65 line-height, heading,
    /// paragraph and list margins, task lists, image width. How elements LOOK
    /// (type weight, links, code, tables, blockquotes, rules, controls) is the
    /// Liquid Glass element defaults in `w42-components.css`, driven by the
    /// `--w42-*` design tokens, so a theme change flows through automatically
    /// and the app + spec + artifacts stay visually identical.
    ///
    /// Scoped to `.w42-prose`: apply that class to the spec `<body>` and the
    /// artifact content mount so both render prose the same way. Kept in sync
    /// with `MarkdownDocumentTemplate` (which includes this verbatim).
    public nonisolated static let proseCSS = """
    /* Container: strong enough (a class) to set the base size/color over `body`. */
    .w42-prose {
      font-size: var(--w42-f14, 16px);
      line-height: 1.55;
      color: var(--w42-text-primary);
      word-wrap: break-word;
      overflow-wrap: anywhere;
    }
    /* Prose RHYTHM only: margins, list indents and task lists. How elements look
       (type weight, links, code, tables, quotes, rules) comes from the Liquid
       Glass element defaults in w42-components.css. Element rules are wrapped in
       :where() so they carry ZERO specificity from the scope: component classes
       (.w42-table, .w42-code-block, …) always win on the same element. */
    :where(.w42-prose) > :first-child { margin-top: 0; }
    :where(.w42-prose) h1, :where(.w42-prose) h2, :where(.w42-prose) h3,
    :where(.w42-prose) h4, :where(.w42-prose) h5, :where(.w42-prose) h6 {
      line-height: 1.25;
      margin: var(--w42-s16, 16px) 0 var(--w42-s4, 4px);
    }
    :where(.w42-prose) h1 { margin-bottom: var(--w42-s8, 8px); }
    :where(.w42-prose) h3 { margin-top: var(--w42-s12, 12px); }
    :where(.w42-prose) h4 { margin-top: var(--w42-s8, 8px); margin-bottom: 0; }
    :where(.w42-prose) p { margin: 0 0 var(--w42-s12, 12px); }
    :where(.w42-prose) ul, :where(.w42-prose) ol { margin: 0 0 var(--w42-s12, 12px); padding-left: 1.6em; }
    :where(.w42-prose) li { margin: var(--w42-s4, 4px) 0; }
    :where(.w42-prose) li.task-list-item { list-style: none; margin-left: -1.3em; }
    :where(.w42-prose) li.task-list-item input { margin-right: 0.5em; }
    :where(.w42-prose) img { max-width: 100%; height: auto; }
    """

    /// The **syntax-highlight theme** — maps highlight.js token scopes onto the
    /// `--w42-syntax-*` tokens, which are the SAME palette the native code-file
    /// editor uses (`EditorSyntaxPalette`: base One Dark/Light overlaid with the
    /// active theme's `editor:` overrides). So a code block in an artifact or a
    /// spec renders with exactly the editor's colours, in light and dark, and
    /// tracks any theme customization — one cohesive code theme across the app.
    /// The `.hljs` container is transparent so it composes with the existing
    /// `pre` / `.w42-code-block` surface — this only colours the TOKENS. Injected
    /// by both the artifact and spec templates alongside `highlightJS`. Attribute
    /// styling matches the editor: keywords bold, comments italic.
    public nonisolated static let highlightCSS = """
    .hljs { background: transparent; color: var(--w42-syntax-text); }
    .hljs-comment, .hljs-quote { color: var(--w42-syntax-comment); font-style: italic; }
    .hljs-keyword, .hljs-selector-tag, .hljs-literal.hljs-keyword,
    .hljs-doctag, .hljs-formula { color: var(--w42-syntax-keyword); font-weight: 600; }
    .hljs-string, .hljs-regexp, .hljs-char, .hljs-char.escape_,
    .hljs-meta .hljs-string, .hljs-template-tag, .hljs-template-variable {
      color: var(--w42-syntax-string);
    }
    .hljs-number, .hljs-literal, .hljs-boolean { color: var(--w42-syntax-number); }
    .hljs-type, .hljs-class .hljs-title, .hljs-title.class_,
    .hljs-title.class_.inherited__, .hljs-built_in, .hljs-builtin-name {
      color: var(--w42-syntax-type);
    }
    .hljs-title, .hljs-title.function_, .hljs-function .hljs-title, .hljs-section {
      color: var(--w42-syntax-function);
    }
    .hljs-attr, .hljs-attribute, .hljs-selector-attr, .hljs-selector-pseudo,
    .hljs-meta, .hljs-meta .hljs-keyword {
      color: var(--w42-syntax-attribute);
    }
    .hljs-variable, .hljs-property, .hljs-params, .hljs-selector-class,
    .hljs-selector-id, .hljs-tag, .hljs-name, .hljs-symbol, .hljs-bullet {
      color: var(--w42-syntax-variable);
    }
    .hljs-link { color: var(--w42-syntax-function); text-decoration: underline; }
    .hljs-strong, .hljs-emphasis { color: var(--w42-syntax-text); }
    .hljs-strong { font-weight: 700; }
    .hljs-emphasis { font-style: italic; }
    .hljs-addition { color: var(--w42-green); background: color-mix(in srgb, var(--w42-green) 12%, transparent); display: inline-block; width: 100%; }
    .hljs-deletion { color: var(--w42-red); background: color-mix(in srgb, var(--w42-red) 12%, transparent); display: inline-block; width: 100%; }
    """

    /// JS that syntax-highlights every fenced code block using the bundled
    /// highlight.js library (mirrors `mermaidJS`). Parameterized by the URL the
    /// library is served from (canvas loopback server / markdown scheme handler)
    /// so the two surfaces can never drift. Strict no-op when the page has no
    /// code blocks (the 120KB library is never even loaded); skips mermaid
    /// blocks (owned by `mermaidJS`) and pathologically large blocks; guarded
    /// against double-install.
    public nonisolated static func highlightJS(src: String = highlightAssetPath) -> String {
    """
    (function () {
      "use strict";
      if (window.__w42HighlightInstalled) { return; }
      window.__w42HighlightInstalled = true;

      var SRC = "\(src)";
      var MAX = 200000; // skip pathologically large blocks (perf guard)

      // Code blocks worth highlighting: <pre><code> that is NOT a mermaid
      // graph (mermaid.js owns those) and NOT already highlighted.
      function blocks() {
        var out = [];
        var nodes = document.querySelectorAll("pre > code");
        for (var i = 0; i < nodes.length; i++) {
          var c = nodes[i];
          var cls = c.className || "";
          if (/(^|\\s)(language|lang)-mermaid(\\s|$)/.test(cls)) { continue; }
          if (c.dataset && c.dataset.highlighted) { continue; }
          if ((c.textContent || "").length > MAX) { continue; }
          out.push(c);
        }
        return out;
      }

      function run() {
        var list = blocks();
        if (list.length === 0) { return; } // never load the library

        function highlight() {
          try {
            if (!window.hljs) { return; }
            try { window.hljs.configure({ ignoreUnescapedHTML: true }); } catch (e) {}
            for (var i = 0; i < list.length; i++) {
              try { window.hljs.highlightElement(list[i]); } catch (e) {}
            }
          } catch (err) {
            if (window.console && console.error) { console.error(err); }
          }
        }

        if (window.hljs) { highlight(); return; }

        var s = document.createElement("script");
        s.src = SRC;
        s.onload = highlight;
        s.onerror = function () {
          if (window.console && console.error) {
            console.error("Failed to load bundled highlight.js from " + SRC);
          }
        };
        (document.head || document.documentElement).appendChild(s);
      }

      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", run);
      } else {
        run();
      }
    })();
    """
    }

    /// The shell's former inline component runtime. The tag runtime, including the
    /// code, table, mockup and diagram cards, now lives in `w42-components.js`
    /// (see `componentLibraryJS()`), so this is empty. Kept so SDK 2.3.x call sites
    /// still link; do not inject it.
    @available(*, deprecated, message: "The tag runtime moved into w42-components.js; use componentLibraryJS().")
    public nonisolated static let componentsJS = ""

    /// CSS for diagrams that are intercepted into a card. Every diagram is
    /// wrapped in a centered, natural-width `w42-diagram-card` (a native-styled
    /// HTML header with the title + zoom/reset/expand controls, plus a
    /// `w42-diagram-slot` body). The card only shrinks when its container is
    /// narrower than the diagram. Rendering the header in the
    /// page keeps it reliably visible (native content composited over a
    /// WKWebView in a tile is obscured by the web layer). The header's Expand
    /// button posts to the native host to open the true native dialog; crisp
    /// zoom is driven in-page via the `__w42Diagram` viewBox bridge (see
    /// `diagramControlsJS`).
    public nonisolated static let diagramControlsCSS = """
    /* Neutralize the mermaid wrapper's own card styling. The bridge below owns
       the visible card and lets it retain the graph's natural width. */
    .w42-mermaid {
      display: block;
      align-items: stretch;
      overflow-x: hidden;
      margin: 0;
      padding: 0;
      background: transparent;
      border: none;
    }
    .w42-mermaid > pre.mermaid,
    pre.mermaid {
      max-width: 100%;
      margin: 0;
      text-align: left;
    }
    /* ── Refined diagram styling (confirmed direction) ───────────────────────
       Rounded ELEVATED node surfaces with a soft depth shadow; accent used only
       on node borders + arrowheads (never as a fill); tinted rounded subgraph
       clusters; thinner, muted edges. Edge labels stay INLINE (mermaid default —
       small surface backing over the line, no pill) and label text keeps
       mermaid's own weight so the node boxes it sized aren't overrun (a heavier
       weight than measured truncates the last characters). The app font comes
       from themeVariables.fontFamily (used for BOTH measurement and render, so
       no truncation). All --w42-* driven so light/dark tracks automatically. */
    .w42-mermaid svg .node > rect,
    .w42-mermaid svg .node > polygon,
    .w42-mermaid svg .node > circle {
      rx: 12px; ry: 12px;
      fill: var(--w42-elevated) !important;
      stroke: color-mix(in srgb, var(--w42-accent) 42%, transparent) !important;
      stroke-width: 1.4px !important;
    }
    .w42-mermaid svg .node {
      filter: drop-shadow(0 1px 2px rgba(0,0,0,0.14)) drop-shadow(0 4px 10px rgba(0,0,0,0.10));
    }
    .w42-mermaid svg .cluster rect {
      rx: 18px; ry: 18px;
      fill: color-mix(in srgb, var(--w42-accent) 6%, var(--w42-surface)) !important;
      stroke: color-mix(in srgb, var(--w42-accent) 22%, transparent) !important;
    }
    .w42-mermaid svg .edgePath path,
    .w42-mermaid svg .flowchart-link {
      stroke: color-mix(in srgb, var(--w42-text-tertiary) 85%, transparent) !important;
      stroke-width: 1.6px !important;
    }
    .w42-mermaid svg marker path {
      fill: color-mix(in srgb, var(--w42-text-tertiary) 85%, transparent) !important;
    }
    /* ── Shared component card base ──────────────────────────────────────
       Every embedded component (diagram, code, table, flutter-mockup) is a
       CARD: a header bar (title + right-aligned action buttons) over a body.
       Metrics are tuned to read at CONTENT scale, matching the app's widget
       tiles — deliberately larger than the old tiny diagram header. The
       `.w42-diagram-*` classes alias the base so the diagram bridge keeps
       working unchanged while it migrates onto the generic builder. */
    .w42-component-card,
    .w42-diagram-card {
      display: block;
      width: 100%;
      margin: 16px 0;
      box-sizing: border-box;
      border-radius: var(--w42-r-panel);
      background:
        linear-gradient(var(--w42-glass-tint), var(--w42-glass-tint)),
        var(--w42-glass-fill);
      -webkit-backdrop-filter: blur(var(--w42-glass-blur)) saturate(180%);
      backdrop-filter: blur(var(--w42-glass-blur)) saturate(180%);
      box-shadow:
        0 18px 48px var(--w42-glass-shadow),
        0 0 0 0.5px var(--w42-glass-rim),
        inset 0 1px 0 var(--w42-glass-glow);
      overflow: hidden;
    }
    @media (prefers-reduced-transparency: reduce) {
      .w42-component-card,
      .w42-diagram-card {
        background: var(--w42-surface);
        -webkit-backdrop-filter: none;
        backdrop-filter: none;
      }
    }
    /* Generic component cards remain full-width. Diagram cards override only
       their own width: fit-content is the safe pre-measurement fallback, then
       diagramControlsJS assigns the measured natural pixel width. */
    .w42-diagram-card {
      width: fit-content;
      max-width: 100%;
      margin-left: auto;
      margin-right: auto;
      box-sizing: border-box;
    }
    .w42-component-header,
    .w42-diagram-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      height: 44px;
      padding: 0 var(--w42-s8) 0 var(--w42-s12);
      box-sizing: border-box;
      border-bottom: 0.5px solid var(--w42-separator);
      font-family: var(--w42-font-family);
      user-select: none; -webkit-user-select: none;
    }
    .w42-component-left,
    .w42-diagram-header .w42-dh-left {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      min-width: 0;
      overflow: hidden;
    }
    .w42-component-icon,
    .w42-diagram-header .w42-dh-icon {
      flex: 0 0 auto;
      width: 18px;
      height: 18px;
      display: inline-flex;
      color: var(--w42-label-secondary);
    }
    .w42-component-icon svg,
    .w42-diagram-header .w42-dh-icon svg { width: 100%; height: 100%; display: block; }
    .w42-component-title,
    .w42-diagram-header .w42-dh-title {
      font-size: var(--w42-f13);
      font-weight: 600;
      color: var(--w42-label-primary);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .w42-component-actions,
    .w42-diagram-header .w42-dh-buttons {
      display: inline-flex;
      align-items: center;
      gap: 1px;
      flex: 0 0 auto;
    }
    /* Action Button (bordered, kit): a 30pt capsule on the secondary fill. */
    .w42-component-action-btn,
    .w42-diagram-header .w42-dh-btn {
      all: unset;
      box-sizing: border-box;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 5px;
      width: 30px;
      height: 30px;
      border-radius: var(--w42-r-pill);
      cursor: pointer;
      color: var(--w42-label-primary);
      background: var(--w42-fill-secondary);
      transition: background 0.12s ease, color 0.12s ease;
    }
    .w42-component-action-btn:hover,
    .w42-diagram-header .w42-dh-btn:hover,
    .w42-component-action-btn:active,
    .w42-diagram-header .w42-dh-btn:active {
      background: var(--w42-fill-primary);
    }
    .w42-component-action-btn:focus-visible,
    .w42-diagram-header .w42-dh-btn:focus-visible {
      outline: var(--w42-focus-ring) solid color-mix(in srgb, var(--w42-accent) 50%, transparent);
    }
    .w42-component-action-btn svg,
    .w42-diagram-header .w42-dh-btn svg {
      width: 16px;
      height: 16px;
      display: block;
    }
    /* Active state for the mockup's app-theme toggle. */
    .w42-component-action-btn.w42-active {
      color: var(--w42-on-accent);
      background: var(--w42-accent);
    }
    /* Momentary "✓ Copied" confirmation — the button widens to show the label. */
    .w42-component-action-btn.w42-done {
      width: auto;
      padding: 0 var(--w42-s12);
      color: var(--w42-chip-fg-success);
      background: var(--w42-chip-fill);
    }
    .w42-done-label { font: 500 var(--w42-f11) var(--w42-font-family); }
    .w42-component-body,
    .w42-diagram-slot {
      display: block;
      width: 100%;
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }
    /* Fail-loud error state (component self-validation, .17): the body shows
       the error message instead of a blank/broken render. */
    .w42-component-error .w42-component-body {
      padding: 12px 14px;
      color: var(--w42-chip-fg-failure);
      font-family: var(--w42-font-mono);
      font-size: var(--w42-f11);
      line-height: 1.5;
      white-space: pre-wrap;
      word-break: break-word;
    }
    /* Flutter mockup: device picker + device-framed iframe (scaled to fit). */
    .w42-mockup-picker {
      all: unset;
      box-sizing: border-box;
      appearance: none; -webkit-appearance: none;
      cursor: pointer;
      font: 500 var(--w42-f11) var(--w42-font-family);
      color: var(--w42-label-primary);
      /* A visible chevron caret + a chip background so it clearly reads as a choice.
         Height matches the action buttons (30px) so the header controls align;
         line-height matches height so the (appearance:none) select text centers. */
      height: 30px;
      line-height: 30px;
      background-color: var(--w42-fill-secondary);
      background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6' fill='none' stroke='%238a8a8f' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M1 1l4 4 4-4'/%3E%3C/svg%3E");
      background-repeat: no-repeat;
      background-position: right 9px center;
      border-radius: var(--w42-r-pill);
      padding: 0 26px 0 14px;
      transition: background-color 0.12s ease;
    }
    .w42-mockup-picker:hover {
      background-color: var(--w42-fill-primary);
    }
    .w42-mockup-picker:focus-visible {
      outline: var(--w42-focus-ring) solid color-mix(in srgb, var(--w42-accent) 50%, transparent);
    }
    /* Dropdown options render in the native menu — keep them readable in dark UIs. */
    .w42-mockup-picker option { color: #1a1a1a; }
    .w42-mockup-stage {
      position: relative;
      display: flex;
      align-items: flex-start;
      justify-content: center;
      padding: 8px;
      overflow: hidden;
      background: var(--w42-backdrop, #f2f2f5);
    }
    .w42-mockup-scaler { transform-origin: top center; flex: 0 0 auto; }
    .w42-mockup-frame {
      position: relative;
      display: flex; flex-direction: column;
      overflow: hidden;
      border-radius: 20px;
      border: 1px solid var(--w42-elevated, rgba(120,120,128,0.28));
      background: #000;
      box-shadow: 0 8px 28px rgba(0,0,0,0.20);
    }
    /* Top safe area: the OS status bar (time + signal/wifi/battery) over the black bezel. */
    .w42-mockup-statusbar {
      flex: 0 0 auto; position: relative; z-index: 2;
      display: flex; align-items: center; justify-content: space-between;
      padding: 0 26px 0 30px; color: #fff;
      font: 600 15px var(--w42-font-family, -apple-system, system-ui, sans-serif);
    }
    .w42-mockup-android .w42-mockup-statusbar { padding: 0 16px; font-size: 13px; }
    .w42-mockup-sb-time { letter-spacing: 0.3px; }
    .w42-mockup-android .w42-mockup-sb-time { font-weight: 500; }
    .w42-mockup-sb-icons { display: flex; align-items: center; gap: 6px; }
    .w42-mockup-sb-icons svg { height: 12px; width: auto; display: block; }
    /* The app screen, inset between the two safe areas. */
    .w42-mockup-screen { flex: 1 1 auto; position: relative; overflow: hidden; background: #fff; }
    .w42-mockup-iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; display: block; background: #fff; }
    /* Bottom safe area: the home indicator (iOS) / gesture bar (Android). */
    .w42-mockup-home {
      flex: 0 0 auto; position: relative; z-index: 2;
      display: flex; align-items: center; justify-content: center;
    }
    .w42-mockup-home-bar { width: 36%; max-width: 148px; height: 5px; border-radius: 3px; background: rgba(255,255,255,0.85); }
    .w42-mockup-android .w42-mockup-home-bar { width: 28%; height: 4px; background: rgba(255,255,255,0.6); }
    .w42-mockup-ipados .w42-mockup-home-bar { width: 22%; }
    /* Device cutouts: Dynamic Island (iPhone) / punch-hole (Pixel), in the status-bar area. */
    .w42-mockup-chrome { position: absolute; top: 0; left: 0; right: 0; height: 54px; z-index: 3; pointer-events: none; }
    .w42-mockup-chrome-island::before {
      content: ""; position: absolute; top: 12px; left: 50%; transform: translateX(-50%);
      width: 30%; max-width: 118px; height: 30px; background: #000; border-radius: 16px;
      box-shadow: inset 0 0 0 1px rgba(255,255,255,0.10);
    }
    /* Camera lens inside the island so it reads on the black bezel. */
    .w42-mockup-chrome-island::after {
      content: ""; position: absolute; top: 20px; left: 50%; transform: translateX(31px);
      width: 9px; height: 9px; border-radius: 50%;
      background: radial-gradient(circle at 35% 35%, #3a3a45 0 35%, #101014 60%);
      box-shadow: 0 0 0 1px rgba(255,255,255,0.05);
    }
    .w42-mockup-chrome-punch::before {
      content: ""; position: absolute; top: 11px; left: 50%; transform: translateX(-50%);
      width: 12px; height: 12px; border-radius: 50%;
      background: radial-gradient(circle at 35% 35%, #2c2c34 0 35%, #050507 60%);
      box-shadow: 0 0 0 1px rgba(255,255,255,0.08);
    }
    /* The 42 brand loader — THE shared loading indicator for every component. */
    .w42-loader {
      display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 14px;
    }
    .w42-loader-mark { width: 76px; height: 76px; }
    .w42-loader-mark svg, .w42-loader42 { width: 100%; height: 100%; display: block; }
    .w42-l42-o { fill: #FF8A3D; }
    .w42-l42-v { fill: #5B21B6; }
    .w42-l42-shade { fill: rgba(60,60,67,0.14); }
    .w42-loader-text {
      font: 500 13px var(--w42-font-family, -apple-system, system-ui, sans-serif);
      color: var(--w42-text-secondary, #6b6b70); text-align: center;
    }
    @media (prefers-color-scheme: dark) {
      .w42-l42-o { fill: #FFA060; }
      .w42-l42-v { fill: #7A49E1; }
      .w42-l42-shade { fill: rgba(235,235,245,0.14); }
    }
    /* Reduced motion mirrors the native fallback: the fully-painted static mark. */
    @media (prefers-reduced-motion: reduce) {
      .w42-l42-mask { mask: none !important; -webkit-mask: none !important; }
      .w42-l42-shade { display: none; }
    }
    /* Loader overlay centered on the device while the mockup compiles. */
    .w42-mockup-loading { position: absolute; inset: 0; z-index: 4; }
    .w42-mockup-status {
      position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%);
      font: 500 var(--w42-f11) var(--w42-font-family);
      color: var(--w42-label-secondary);
      background: var(--w42-glass-fill);
      padding: 8px 14px; border-radius: var(--w42-r-pill);
      box-shadow: 0 0 0 0.5px var(--w42-glass-rim);
    }
    .w42-mockup-status-error { color: var(--w42-chip-fg-failure); }
    /* The diagram body is pannable; other component bodies are not. */
    .w42-diagram-slot { cursor: grab; }
    .w42-diagram-slot:active { cursor: grabbing; }
    .w42-diagram-card.w42-diagram-sized .w42-diagram-slot > svg.w42-diagram {
      display: block;
      width: 100%;
      height: auto;
      max-width: none;
    }
    """

    /// The **diagram bridge**: JS that INTERCEPTS every diagram and wraps it in
    /// a card with a native-styled HTML header. Universal + non-opt-out:
    ///   1. Detects every diagram via a tag list (mermaid v11 svgs, anything in
    ///      a mermaid wrapper, or any sizeable svg) — extend `DIAGRAM_SELECTOR`
    ///      to intercept future tags. The agent cannot opt in or out. (Our own
    ///      header control icons are excluded so they aren't mistaken for
    ///      diagrams.)
    ///   2. Wraps each in a `w42-diagram-card`: an HTML header (title + zoom /
    ///      reset / expand buttons, styled to match macOS) + a centered body
    ///      sized to the diagram's natural bounds and capped by its container.
    ///      Rendering the header in-page keeps it reliably visible (native
    ///      content over a WKWebView in a tile is obscured by the web layer).
    ///   3. Handles pan/zoom GESTURES in-page (synchronous, no native
    ///      round-trip, so it's fast) and drives CRISP vector zoom via the svg
    ///      viewBox. Zoom bounds (`getBBox`, viewBox fallback) are captured
    ///      lazily and retried on each interaction — they gate ZOOM only.
    ///   4. The Expand button posts `{type:"expand", id}` to
    ///      `window.webkit.messageHandlers.w42Diagram`; the native host fetches
    ///      the diagram's SVG (`__w42Diagram.svg(id)`) and presents it full-size
    ///      in a genuinely native dialog (a sheet, where native renders fine).
    /// Uses a bounded poll (no MutationObserver) so it can never enter an
    /// observe/mutate loop, marks each diagram once, is a no-op with no diagram
    /// (and with no native host — plain browsers still get naturally sized,
    /// carded diagrams whose Expand is inert), and is self-guarded against
    /// double-install.
    public nonisolated static let diagramControlsJS = """
    (function () {
      "use strict";
      if (window.__w42DiagramBridgeInstalled) { return; }
      window.__w42DiagramBridgeInstalled = true;

      function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }

      var HANDLER = "w42Diagram";
      // Selector for svgs that live inside a known diagram container. Extend
      // this (and `isDiagram`) to intercept future tags — the interception is
      // universal, never something a document opts into.
      var DIAGRAM_SELECTOR = ".w42-mermaid, .mermaid, pre.mermaid, code.language-mermaid";
      var MIN_CARD_WIDTH = 280; // enough room for title + four header controls
      var seq = 0;
      var reg = {}; // id -> { svg, slot, base, cur, ar, minw, maxw }

      function post(msg) {
        try {
          if (window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers[HANDLER]) {
            window.webkit.messageHandlers[HANDLER].postMessage(msg);
          }
        } catch (e) { /* no native host (plain browser) — ignore */ }
      }

      function isDiagram(svg) {
        if (svg.__w42Diagram) { return false; }
        // Our own header control icons are <svg>s inside .w42-mermaid — never
        // treat them (or anything in a card header) as a diagram.
        if (svg.closest(".w42-diagram-header")) { return false; }
        var id = svg.getAttribute("id") || "";
        if (id.indexOf("mermaid") === 0) { return true; }
        if (svg.getAttribute("aria-roledescription")) { return true; }
        if (svg.closest(DIAGRAM_SELECTOR)) { return true; }
        if (svg.classList.contains("w42-diagram")) { return true; }
        var r = svg.getBoundingClientRect();
        return r.width >= 120 && r.height >= 80;
      }

      function applyVB(st) {
        if (!st.cur) { return; }
        st.svg.setAttribute("viewBox",
          st.cur.x + " " + st.cur.y + " " + st.cur.w + " " + st.cur.h);
      }
      function clampPan(st) {
        var mx = st.cur.w * 0.5, my = st.cur.h * 0.5;
        st.cur.x = clamp(st.cur.x, st.base.x - mx, st.base.x + st.base.w - st.cur.w + mx);
        st.cur.y = clamp(st.cur.y, st.base.y - my, st.base.y + st.base.h - st.cur.h + my);
      }

      // Size the visible card from the diagram's tight content bounds. The SVG
      // fills THIS card, not the entire content column. max-width:100% provides
      // responsive shrink-to-fit while height:auto preserves the viewBox ratio.
      function sizeCard(st) {
        if (!st.base) { return false; }
        var natural = Math.max(MIN_CARD_WIDTH, Math.ceil(st.base.w));
        st.card.style.width = natural + "px";
        st.card.style.maxWidth = "100%";
        st.card.classList.add("w42-diagram-sized");
        st.svg.style.display = "block";
        st.svg.style.width = "100%";
        st.svg.style.height = "auto";
        st.svg.style.maxWidth = "none";
        st.svg.removeAttribute("width");
        st.svg.removeAttribute("height");
        return true;
      }

      // Capture the base viewBox (tight getBBox content bounds, with the SVG
      // viewBox as fallback). May fail while the diagram is still being
      // laid out / rendered — returns false and is retried every report. This
      // gates ZOOM only, never whether the native component appears.
      function captureBase(st) {
        if (st.base) { return true; }
        var bb = null;
        try { bb = st.svg.getBBox(); } catch (e) {}
        var base = null;
        if (bb && bb.width > 1 && bb.height > 1) {
          base = { x: bb.x, y: bb.y, w: bb.width, h: bb.height };
        } else {
          var vb = st.svg.viewBox && st.svg.viewBox.baseVal;
          if (vb && vb.width && vb.height) {
            base = { x: vb.x, y: vb.y, w: vb.width, h: vb.height };
          }
        }
        if (!base) { return false; }
        var pad = 0.03;
        base = {
          x: base.x - base.w * pad, y: base.y - base.h * pad,
          w: base.w * (1 + 2 * pad), h: base.h * (1 + 2 * pad)
        };
        st.base = base;
        st.cur = { x: base.x, y: base.y, w: base.w, h: base.h };
        st.ar = base.h / base.w;
        st.minw = base.w / 16;
        st.maxw = base.w;
        applyVB(st);
        sizeCard(st);
        return true;
      }

      // Wrap `svg` in a CARD we control (once): a reserved header strip (the
      // native overlay draws the title + controls there) + a body slot holding
      // the diagram. Returns { card, header, slot } or null.
      function cardFor(svg) {
        var existing = svg.closest(".w42-diagram-card");
        if (existing) {
          return {
            card: existing,
            header: existing.querySelector(".w42-diagram-header"),
            slot: existing.querySelector(".w42-diagram-slot")
          };
        }
        var parent = svg.parentNode;
        if (!parent) { return null; }
        var card = document.createElement("div");
        card.className = "w42-component-card w42-diagram-card";
        var header = document.createElement("div");
        header.className = "w42-component-header w42-diagram-header";
        var slot = document.createElement("div");
        slot.className = "w42-component-body w42-diagram-slot";
        parent.insertBefore(card, svg);
        card.appendChild(header);
        card.appendChild(slot);
        slot.appendChild(svg);
        return { card: card, header: header, slot: slot };
      }

      // Best-effort human title for the card header. Prefers the diagram's
      // <title>, then a data-w42-title override on an ancestor, else "Diagram".
      function titleFor(svg) {
        var t = svg.querySelector("title");
        if (t && t.textContent && t.textContent.trim()) { return t.textContent.trim(); }
        var host = svg.closest("[data-w42-title]");
        if (host) { return host.getAttribute("data-w42-title"); }
        return "Diagram";
      }

      // Intercept a diagram: mark seen, wrap it, register it, then size from its
      // measured natural bounds. Until bounds are available the authored SVG
      // keeps its intrinsic dimensions inside the fit-content card.
      function prep(svg) {
        svg.__w42Diagram = true;
        var parts = cardFor(svg);
        if (!parts) { return; }
        var id = "w42d-" + (++seq);
        parts.card.setAttribute("data-w42-diagram-id", id);
        svg.classList.add("w42-diagram");
        svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
        var st = {
          id: id, svg: svg, card: parts.card, header: parts.header, slot: parts.slot,
          title: titleFor(svg), base: null, cur: null
        };
        reg[id] = st;
        captureBase(st);
        attachGestures(st);
        buildHeader(st);
      }

      // SF-Symbol-like stroke icons for the header buttons.
      var ICON = {
        diagram: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><rect x="5.5" y="1.5" width="5" height="3.2" rx="0.7"/><rect x="1.5" y="10.8" width="4.6" height="3.2" rx="0.7"/><rect x="9.9" y="10.8" width="4.6" height="3.2" rx="0.7"/><path d="M8 4.7V8M8 8H3.8v2.8M8 8h4.2v2.8"/></svg>',
        zoomOut: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"><circle cx="6.75" cy="6.75" r="4.25"/><line x1="9.9" y1="9.9" x2="13.5" y2="13.5"/><line x1="4.75" y1="6.75" x2="8.75" y2="6.75"/></svg>',
        zoomIn: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"><circle cx="6.75" cy="6.75" r="4.25"/><line x1="9.9" y1="9.9" x2="13.5" y2="13.5"/><line x1="4.75" y1="6.75" x2="8.75" y2="6.75"/><line x1="6.75" y1="4.75" x2="6.75" y2="8.75"/></svg>',
        reset: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M13 8a5 5 0 1 1-1.6-3.7"/><path d="M13 2.5V5.2H10.3"/></svg>',
        expand: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M9.5 6.5 13 3"/><path d="M10 3h3v3"/><path d="M6.5 9.5 3 13"/><path d="M6 13H3v-3"/></svg>'
      };

      function mkBtn(label, icon, fn) {
        var b = document.createElement("button");
        b.type = "button";
        b.className = "w42-component-action-btn w42-dh-btn";
        b.title = label;
        b.setAttribute("aria-label", label);
        b.innerHTML = icon;
        b.addEventListener("click", function (e) {
          e.preventDefault(); e.stopPropagation(); fn();
        });
        return b;
      }

      // Populate the (native-styled) HTML card header: title + control buttons.
      // zoom/reset run IN-PAGE (fast); expand posts the SVG to the native host
      // to open the true native dialog.
      function buildHeader(st) {
        var h = st.header;
        h.textContent = "";
        var left = document.createElement("div");
        left.className = "w42-component-left w42-dh-left";
        var ico = document.createElement("span");
        ico.className = "w42-component-icon w42-dh-icon";
        ico.innerHTML = ICON.diagram;
        var title = document.createElement("span");
        title.className = "w42-component-title w42-dh-title";
        title.textContent = st.title;
        left.appendChild(ico);
        left.appendChild(title);
        var group = document.createElement("div");
        group.className = "w42-component-actions w42-dh-buttons";
        group.appendChild(mkBtn("Zoom out", ICON.zoomOut, function () { doZoom(st, 1.3, 0.5, 0.5); }));
        group.appendChild(mkBtn("Zoom in", ICON.zoomIn, function () { doZoom(st, 1 / 1.3, 0.5, 0.5); }));
        group.appendChild(mkBtn("Reset view", ICON.reset, function () { doReset(st); }));
        group.appendChild(mkBtn("Expand", ICON.expand, function () {
          post({ type: "expand", id: st.id });
        }));
        h.appendChild(left);
        h.appendChild(group);
      }

      // Shared viewBox math (used by BOTH the in-page gesture handlers and the
      // native pill). `fx`/`fy` are the 0..1 focal point within the diagram;
      // `dxFrac`/`dyFrac` are pan deltas as a fraction of the current view. All
      // no-op until the base viewBox is captured.
      // captureBase is retried here so a diagram whose bounds weren't ready at
      // first render still becomes interactive on the first click/gesture.
      function doZoom(st, factor, fx, fy) {
        if (!captureBase(st)) { return; }
        if (fx == null) { fx = 0.5; } if (fy == null) { fy = 0.5; }
        var nw = clamp(st.cur.w * factor, st.minw, st.maxw), nh = nw * st.ar;
        st.cur.x += (st.cur.w - nw) * fx; st.cur.y += (st.cur.h - nh) * fy;
        st.cur.w = nw; st.cur.h = nh; clampPan(st); applyVB(st);
      }
      function doPan(st, dxFrac, dyFrac) {
        if (!captureBase(st)) { return; }
        st.cur.x += dxFrac * st.cur.w; st.cur.y += dyFrac * st.cur.h;
        clampPan(st); applyVB(st);
      }
      function doReset(st) {
        if (!captureBase(st)) { return; }
        st.cur = { x: st.base.x, y: st.base.y, w: st.base.w, h: st.base.h };
        applyVB(st);
      }
      function isZoomed(st) { return st.base && st.cur && st.cur.w < st.base.w - 0.5; }

      // In-page gesture handling — SYNCHRONOUS + in-process, so pan/zoom feel
      // instant (no native round-trip per event). Ctrl/Cmd+scroll or trackpad
      // pinch zooms at the cursor; two-finger scroll pans when zoomed; drag
      // pans; double-click resets. The native layer keeps only the pill.
      function attachGestures(st) {
        var slot = st.slot;
        slot.style.cursor = "grab";
        slot.addEventListener("wheel", function (e) {
          if (!captureBase(st)) { return; }
          if (e.ctrlKey || e.metaKey) {
            e.preventDefault();
            var r = st.svg.getBoundingClientRect();
            doZoom(st, Math.exp(e.deltaY * 0.01),
              (e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height);
          } else if (isZoomed(st)) {
            e.preventDefault();
            var r2 = st.svg.getBoundingClientRect();
            doPan(st, e.deltaX / r2.width, e.deltaY / r2.height);
          }
        }, { passive: false });
        var drag = false, lx = 0, ly = 0;
        slot.addEventListener("mousedown", function (e) {
          if (!captureBase(st)) { return; }
          drag = true; lx = e.clientX; ly = e.clientY;
          slot.style.cursor = "grabbing"; e.preventDefault();
        });
        window.addEventListener("mousemove", function (e) {
          if (!drag) { return; }
          var r = st.svg.getBoundingClientRect();
          doPan(st, -(e.clientX - lx) / r.width, -(e.clientY - ly) / r.height);
          lx = e.clientX; ly = e.clientY;
        });
        window.addEventListener("mouseup", function () {
          if (drag) { drag = false; slot.style.cursor = "grab"; }
        });
        slot.addEventListener("dblclick", function (e) { e.preventDefault(); doReset(st); });
      }

      function each(fn) { for (var id in reg) { if (reg.hasOwnProperty(id)) { fn(reg[id]); } } }

      function each(fn) { for (var id in reg) { if (reg.hasOwnProperty(id)) { fn(reg[id]); } } }

      // In-page API driven by the header buttons and gestures. The *All helpers
      // drive every diagram in the document (used by the single-diagram expand
      // dialog's native header).
      window.__w42Diagram = {
        zoom: function (id, factor, fx, fy) { var st = reg[id]; if (st) { doZoom(st, factor, fx, fy); } },
        pan: function (id, dxFrac, dyFrac) { var st = reg[id]; if (st) { doPan(st, dxFrac, dyFrac); } },
        reset: function (id) { var st = reg[id]; if (st) { doReset(st); } },
        zoomAll: function (factor) { each(function (st) { doZoom(st, factor, 0.5, 0.5); }); },
        resetAll: function () { each(doReset); },
        svg: function (id) { var st = reg[id]; return st ? st.svg.outerHTML : ""; }
      };

      function scan() {
        var live = document.getElementsByTagName("svg");
        var list = [];
        for (var i = 0; i < live.length; i++) { list.push(live[i]); }
        for (var j = 0; j < list.length; j++) {
          if (isDiagram(list[j])) { prep(list[j]); }
        }
        // Mermaid can expose the SVG before getBBox has usable bounds. Retry
        // registered-but-unsized diagrams as part of this already-bounded scan;
        // no user gesture or unbounded observer is needed to finish layout.
        each(function (st) { if (!st.base) { captureBase(st); } });
      }

      // Poll long enough to catch late-rendering mermaid (async render), then
      // stop — a bounded, self-terminating loop (no MutationObserver).
      var ticks = 0;
      function tick() { scan(); if (++ticks < 40) { setTimeout(tick, 500); } }

      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", tick);
      } else {
        tick();
      }
    })();
    """

    /// CSS for the inline error overlay banner. Theme-aware: it leans on
    /// the `--w42-*` custom properties emitted by `CanvasTheme.legacyCSS()`
    /// (e.g. `--w42-red`, `--w42-surface`), with hard fallbacks so it
    /// still renders if the theme stylesheet failed to load.
    ///
    /// Exposed as a reusable constant so the server's full-document mode
    /// can inject the same bundle as the composed mode.
    public nonisolated static let overlayCSS = """
    #w42-error-overlay {
      position: fixed;
      left: 0;
      right: 0;
      bottom: 0;
      z-index: 2147483647;
      display: none;
      flex-direction: column;
      gap: 8px;
      max-height: 50vh;
      overflow-y: auto;
      padding: 12px;
      margin: 0;
      box-sizing: border-box;
      font-family: ui-monospace, "SF Mono", Menlo, Monaco, "Courier New", monospace;
      font-size: var(--w42-f12, 12px);
      line-height: 1.45;
      pointer-events: auto;
    }
    #w42-error-overlay.w42-has-errors {
      display: flex;
    }
    .w42-error-item {
      border: 1px solid var(--w42-red, #e5484d);
      border-left-width: 4px;
      border-radius: var(--w42-r-card, 8px);
      background: var(--w42-surface, rgba(229, 72, 77, 0.08));
      color: var(--w42-text-primary, #1a1a1a);
      padding: 10px 12px;
      box-shadow: 0 4px 16px rgba(0, 0, 0, 0.18);
    }
    .w42-error-head {
      display: flex;
      align-items: baseline;
      gap: 8px;
      margin-bottom: 4px;
    }
    .w42-error-badge {
      flex: 0 0 auto;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--w42-red, #e5484d);
      font-size: var(--w42-f10, 10px);
    }
    .w42-error-msg {
      flex: 1 1 auto;
      white-space: pre-wrap;
      word-break: break-word;
      font-weight: 600;
    }
    .w42-error-loc {
      color: var(--w42-text-tertiary, #888);
      font-size: var(--w42-f10, 10px);
      white-space: pre-wrap;
      word-break: break-word;
    }
    .w42-error-stack {
      margin: 6px 0 0;
      padding: 8px;
      background: var(--w42-backdrop, rgba(0, 0, 0, 0.05));
      border-radius: var(--w42-r-input, 6px);
      color: var(--w42-text-secondary, #555);
      font-size: var(--w42-f11, 11px);
      white-space: pre-wrap;
      word-break: break-word;
      overflow-x: auto;
    }
    """

    /// JS for the error overlay. Traps `window.onerror`,
    /// `unhandledrejection`, and patches `console.error`; renders each
    /// failure inline as a stacking, scrollable banner; and POSTs each one
    /// as JSON to ``errorReportPath`` (relative to the canvas root). POST
    /// failures are swallowed so reporting never recurses into the overlay.
    ///
    /// Wrapped in an IIFE and self-guarded against double-install so it is
    /// safe to inject in both composed and full-document modes.
    public nonisolated static let overlayJS = """
    (function () {
      "use strict";
      if (window.__w42ErrorOverlayInstalled) { return; }
      window.__w42ErrorOverlayInstalled = true;

      var REPORT_PATH = "\(errorReportPath)";
      var MAX_ITEMS = 50;
      var reporting = false;

      function ensureOverlay() {
        var el = document.getElementById("w42-error-overlay");
        if (el) { return el; }
        el = document.createElement("div");
        el.id = "w42-error-overlay";
        el.setAttribute("role", "log");
        el.setAttribute("aria-live", "assertive");
        var parent = document.body || document.documentElement;
        parent.appendChild(el);
        return el;
      }

      function textNode(cls, text) {
        var n = document.createElement("div");
        n.className = cls;
        n.textContent = text;
        return n;
      }

      function render(entry) {
        var overlay = ensureOverlay();
        var item = document.createElement("div");
        item.className = "w42-error-item";

        var head = document.createElement("div");
        head.className = "w42-error-head";
        head.appendChild(textNode("w42-error-badge", entry.kind || "error"));
        head.appendChild(textNode("w42-error-msg", entry.message || "Unknown error"));
        item.appendChild(head);

        if (entry.source) {
          var loc = entry.source;
          if (entry.line != null) {
            loc += ":" + entry.line + (entry.column != null ? ":" + entry.column : "");
          }
          item.appendChild(textNode("w42-error-loc", loc));
        }
        if (entry.stack) {
          var pre = document.createElement("pre");
          pre.className = "w42-error-stack";
          pre.textContent = entry.stack;
          item.appendChild(pre);
        }

        overlay.appendChild(item);
        while (overlay.childElementCount > MAX_ITEMS) {
          overlay.removeChild(overlay.firstChild);
        }
        overlay.classList.add("w42-has-errors");
        overlay.scrollTop = overlay.scrollHeight;
      }

      function report(entry) {
        if (reporting) { return; }
        reporting = true;
        try {
          var body = JSON.stringify(entry);
          if (navigator.sendBeacon) {
            try {
              var blob = new Blob([body], { type: "application/json" });
              navigator.sendBeacon(REPORT_PATH, blob);
              reporting = false;
              return;
            } catch (beaconErr) { /* fall through to fetch */ }
          }
          if (window.fetch) {
            fetch(REPORT_PATH, {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: body,
              keepalive: true
            }).catch(function () { /* swallow */ });
          }
        } catch (e) {
          /* never recurse into the overlay from the reporter */
        } finally {
          reporting = false;
        }
      }

      function capture(entry) {
        entry.timestamp = new Date().toISOString();
        try { render(entry); } catch (e) { /* swallow render failures */ }
        report(entry);
      }

      window.addEventListener("error", function (event) {
        if (event && event.error) {
          capture({
            kind: "error",
            message: String(event.message || (event.error && event.error.message) || "Error"),
            source: event.filename || "",
            line: typeof event.lineno === "number" ? event.lineno : null,
            column: typeof event.colno === "number" ? event.colno : null,
            stack: (event.error && event.error.stack) ? String(event.error.stack) : null
          });
        } else if (event) {
          // Resource load error (img/script/link) — has no .error.
          var t = event.target || {};
          capture({
            kind: "resource",
            message: "Failed to load resource",
            source: t.src || t.href || "",
            line: null,
            column: null,
            stack: null
          });
        }
        return false;
      }, true);

      window.addEventListener("unhandledrejection", function (event) {
        var reason = event ? event.reason : undefined;
        var message;
        var stack = null;
        if (reason && typeof reason === "object") {
          message = String(reason.message || reason);
          stack = reason.stack ? String(reason.stack) : null;
        } else {
          message = String(reason);
        }
        capture({
          kind: "unhandledrejection",
          message: message,
          source: "",
          line: null,
          column: null,
          stack: stack
        });
      });

      var nativeConsoleError = (window.console && console.error)
        ? console.error.bind(console)
        : function () {};
      if (window.console) {
        console.error = function () {
          try {
            var parts = [];
            for (var i = 0; i < arguments.length; i++) {
              var a = arguments[i];
              if (a && typeof a === "object") {
                try { parts.push(a.stack || a.message || JSON.stringify(a)); }
                catch (je) { parts.push(String(a)); }
              } else {
                parts.push(String(a));
              }
            }
            capture({
              kind: "console.error",
              message: parts.join(" "),
              source: "",
              line: null,
              column: null,
              stack: null
            });
          } catch (e) {
            /* swallow — never break the page's own console.error */
          }
          return nativeConsoleError.apply(null, arguments);
        };
      }
    })();

    // ── Height-post bridge ───────────────────────────────────────────
    // When this artifact shell runs inside an iframe (embedded via a
    // <w42-artifact> element), post the document scroll height to the
    // parent so the parent can resize the iframe to fit the content
    // with no inner scrollbar. Also fires on a ResizeObserver so
    // content changes that affect height (e.g. mermaid render
    // completing after load) are reported up automatically.
    (function () {
      "use strict";
      if (window.parent === window) { return; }
      if (window.__w42HeightPostInstalled) { return; }
      window.__w42HeightPostInstalled = true;

      function postHeight() {
        try {
          var h = document.documentElement.scrollHeight;
          window.parent.postMessage({ type: "w42-artifact-height", height: h }, "*");
        } catch (e) { /* swallow cross-origin denials (should not occur same-origin) */ }
      }

      if (document.readyState === "complete") {
        postHeight();
      } else {
        window.addEventListener("load", postHeight);
      }

      if (window.ResizeObserver) {
        var ro = new ResizeObserver(function () { postHeight(); });
        ro.observe(document.documentElement);
      }
    })();

    // ── w42-artifact custom element ──────────────────────────────────
    // <w42-artifact id="<artifact-id>" caption="<optional text>">
    // Renders a themed figure wrapping a same-origin iframe whose src
    // is resolved as ../<id>/ relative to the current document URL.
    // The auto-height bridge above keeps the iframe sized to content.
    // Fail-loud: if the iframe doesn't load a real artifact page
    // (#w42-canvas-content absent) the element shows a themed
    // placeholder reading "artifact <id> unavailable".
    (function () {
      "use strict";
      if (!window.customElements || customElements.get("w42-artifact")) { return; }

      function removeSelf(el) {
        try {
          if (el && el.parentNode) { el.parentNode.removeChild(el); }
        } catch (e) {}
      }

      function showPlaceholder(figure, iframe, artifactId) {
        removeSelf(iframe);
        var ph = document.createElement("div");
        ph.className = "w42-artifact-embed-placeholder";
        ph.textContent = "artifact " + artifactId + " unavailable";
        figure.appendChild(ph);
      }

      customElements.define("w42-artifact", class extends HTMLElement {
        connectedCallback() {
          var artifactId = this.getAttribute("id") || "";
          var caption    = this.getAttribute("caption") || "";
          if (!artifactId) { return; }

          /* ---- figure chrome ---- */
          var figure = document.createElement("figure");
          figure.className = "w42-artifact-embed";

          var bar = document.createElement("figcaption");
          bar.className = "w42-artifact-embed-caption";

          var badge = document.createElement("span");
          badge.className = "w42-artifact-embed-badge";
          badge.textContent = "LIVE IMPORT";
          bar.appendChild(badge);

          var idEl = document.createElement("span");
          idEl.className = "w42-artifact-embed-id";
          idEl.textContent = artifactId;
          bar.appendChild(idEl);

          if (caption) {
            bar.appendChild(document.createTextNode(" \u{2014} "));
            var lbl = document.createElement("span");
            lbl.className = "w42-artifact-embed-label";
            lbl.textContent = caption;
            bar.appendChild(lbl);
          }

          figure.appendChild(bar);

          /* ---- iframe ---- */
          var iframe = document.createElement("iframe");
          iframe.className = "w42-artifact-embed-frame";
          iframe.setAttribute("scrolling", "no");

          // Resolve ../<id>/ relative to the current artifact URL so the
          // path works correctly under /<sessionId>-<token>/<currentId>/.
          var src;
          try {
            src = new URL("../" + encodeURIComponent(artifactId) + "/",
              window.location.href).href;
          } catch (e) {
            src = "../" + artifactId + "/";
          }

          /* Height bridge — resize iframe to embedded content height */
          var heightListener = function (event) {
            if (event.source !== iframe.contentWindow) { return; }
            if (!event.data || event.data.type !== "w42-artifact-height") { return; }
            var h = parseInt(event.data.height, 10);
            if (h > 0) { iframe.style.height = h + "px"; }
          };
          window.addEventListener("message", heightListener);

          /* Fail-loud: verify #w42-canvas-content after iframe load.
             A real artifact page always has this element; a flat 404
             page from the server does not. Same-origin iframe so
             contentDocument is accessible without security errors. */
          iframe.addEventListener("load", function () {
            try {
              var doc = iframe.contentDocument;
              if (!doc || !doc.getElementById("w42-canvas-content")) {
                window.removeEventListener("message", heightListener);
                showPlaceholder(figure, iframe, artifactId);
              }
            } catch (e) {
              /* Unexpected cross-origin / security error — show placeholder */
              window.removeEventListener("message", heightListener);
              showPlaceholder(figure, iframe, artifactId);
            }
          });

          iframe.src = src;
          figure.appendChild(iframe);

          /* Replace this element's children with the rendered figure */
          while (this.firstChild) { this.removeChild(this.firstChild); }
          this.appendChild(figure);

          this.__w42HeightListener = heightListener;
        }

        disconnectedCallback() {
          if (this.__w42HeightListener) {
            window.removeEventListener("message", this.__w42HeightListener);
            this.__w42HeightListener = null;
          }
        }
      });
    })();
    """

    /// The kit page's appearance + theme bridge, injected in `<head>` BEFORE first
    /// paint (so a dark OS never flashes light). It does two things:
    ///
    /// 1. Sets/clears ONLY the `dark` class on `<html>` from
    ///    `prefers-color-scheme` and follows live changes. `CanvasTheme.tokensCSS()`
    ///    keys the dark token values on `.dark`, and the kit's Tailwind `dark:`
    ///    variant is `(&:where(.dark, .dark *))`. Other classes on `<html>` (a
    ///    full-document artifact may set its own) are left alone.
    /// 2. Defines `window.__w42.theme.apply(tokens)`, the live re-theme entry point
    ///    `ThemeReactiveLayer` calls on an accent/theme change: it writes the pushed
    ///    `--w42-*` values onto `:root` and re-runs mermaid if present. (Same contract
    ///    the legacy `w42-components.js` provided; kit pages do not load that file.)
    public nonisolated static let appearanceScript = """
    <script>
    (function () {
      var root = document.documentElement;
      var mq = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;
      function sync() { root.classList.toggle("dark", !!(mq && mq.matches)); }
      sync();
      if (mq) {
        if (mq.addEventListener) { mq.addEventListener("change", sync); }
        else if (mq.addListener) { mq.addListener(sync); }
      }
      window.__w42 = window.__w42 || {};
      window.__w42.theme = window.__w42.theme || {
        apply: function (tokens) {
          if (!tokens) { return; }
          try {
            for (var k in tokens) {
              if (!Object.prototype.hasOwnProperty.call(tokens, k)) { continue; }
              var name = (k.indexOf("--") === 0) ? k : ("--w42-" + k);
              root.style.setProperty(name, String(tokens[k]));
            }
          } catch (e) { if (window.console && console.error) { console.error("w42 theme.apply:", e); } }
          try {
            if (window.__w42.mermaid && typeof window.__w42.mermaid.rerender === "function") {
              window.__w42.mermaid.rerender();
            }
          } catch (e2) {}
        }
      };
    })();
    </script>
    """

    /// Composes a complete, theme-matched HTML document from an agent
    /// content fragment, in the LEGACY Web Kit (artifacts saved before the Preline
    /// kit, i.e. `meta.json` without `kit`). New artifacts use `composeKit`.
    ///
    /// The agent supplies only the markup it wants shown; this wraps it in
    /// the document shell (`<head>` with charset/viewport/`color-scheme` +
    /// the theme CSS inlined), drops it into a content mount, and injects
    /// the error overlay (CSS + JS). The `content` is rendered as markup
    /// verbatim — it is intentionally *not* HTML-escaped, because the
    /// whole point of the canvas is to render agent HTML. The shell's own
    /// constants (theme/overlay) are fixed and cannot be broken by the
    /// content because the content is the last thing placed into the body.
    ///
    /// The component stylesheet (`w42-components.css`) is included via a
    /// `<link>` tag so agent content can freely use `.w42-*` component
    /// classes. The `ArtifactServer` serves the asset at
    /// `_w42/w42-components.css` relative to every artifact root. The
    /// `<w42-*>` tag runtime loads the same way from `_w42/w42-components.js`.
    ///
    /// - Parameters:
    ///   - content: the agent's HTML fragment (rendered as markup as-is).
    ///   - themeCSS: the theme stylesheet to inline, normally the output
    ///     of `CanvasTheme.legacyCSS()`.
    /// - Returns: a complete `<!doctype html>` document string.
    public nonisolated static func composeLegacy(content: String, themeCSS: String) -> String {
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>Canvas</title>
        <style>
        \(themeCSS)
        </style>
        <link rel="stylesheet" href="\(ArtifactShellAssets.legacyCSSAssetPath)">
        <style>
        \(proseCSS)
        </style>
        <style>
        \(overlayCSS)
        </style>
        <style>
        \(diagramControlsCSS)
        </style>
        <style>
        \(highlightCSS)
        </style>
        </head>
        <body>
        <main id="w42-canvas-content" class="w42-prose">
        \(content)
        </main>
        <script>
        \(overlayJS)
        </script>
        <script>
        \(mermaidJS())
        </script>
        <script src="\(ArtifactShellAssets.legacyJSAssetPath)"></script>
        <script>
        \(highlightJS())
        </script>
        <script>
        \(diagramControlsJS)
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Kit pages (Preline + Work42 theme)

    /// Optional kit runtimes a page may need (`KitCompiler.detectRuntime`).
    public nonisolated static let kitRuntimePreline = "preline"
    public nonisolated static let kitRuntimeW42 = "w42"

    /// What a kit page puts in `<head>`: the token stylesheet, the appearance
    /// script (so the `dark` class is set before first paint), the compiled
    /// `kit.css` (or, when the per-artifact compile failed or has not run, the
    /// precompiled `w42-kit-full.css`), and the error overlay's CSS. No element
    /// rules: the kit (Tailwind + Preline) owns every element style.
    public nonisolated static func kitHead(themeCSS: String, hasKitCSS: Bool) -> String {
        let kit = hasKitCSS ? "kit.css" : "\(ArtifactShellAssets.kitAssetPrefix)w42-kit-full.css"
        return """
        <style>
        \(themeCSS)
        </style>
        \(appearanceScript)
        <link rel="stylesheet" href="\(kit)">
        <style>
        \(overlayCSS)
        </style>
        <style>
        \(highlightCSS)
        </style>

        """
    }

    /// What a kit page puts before `</body>`: the error overlay, mermaid and
    /// highlight auto-renderers (both no-ops when the page has no diagram or code
    /// block), then the optional runtimes the artifact needs.
    public nonisolated static func kitBodyEnd(runtime: [String]) -> String {
        var out = """
        <script>
        \(overlayJS)
        </script>
        <script>
        \(mermaidJS())
        </script>
        <script>
        \(highlightJS())
        </script>

        """
        if runtime.contains(kitRuntimePreline) {
            out += "<script src=\"\(ArtifactShellAssets.kitAssetPrefix)preline/preline.js\"></script>\n"
        }
        if runtime.contains(kitRuntimeW42) {
            // The diagram bridge (cards for every rendered diagram) and the mockup / toast runtime.
            out += "<script src=\"\(ArtifactShellAssets.kitAssetPrefix)w42-diagram.js\"></script>\n"
            out += "<script src=\"\(ArtifactShellAssets.kitAssetPrefix)w42-kit.js\"></script>\n"
        }
        return out
    }

    /// The shell's own page rules for a FRAGMENT artifact (a full document owns its
    /// own). Plain CSS inside `@layer base` — Tailwind only compiles the classes in
    /// the artifact's `index.html`, so the shell cannot rely on utility classes —
    /// which keeps every utility the artifact uses able to override it.
    nonisolated static let kitShellCSS = """
    @layer theme, base, components, utilities;
    @layer base {
      html { background: var(--w42-backdrop); }
      body {
        margin: 0;
        background: var(--w42-backdrop);
        color: var(--w42-text-primary);
        font-family: var(--w42-font-family);
        font-size: var(--w42-f13);
        line-height: 1.45;
        -webkit-font-smoothing: antialiased;
        -webkit-text-size-adjust: 100%;
      }
      #w42-canvas-content { padding: var(--w42-s16); }
    }
    """

    /// Composes a kit page.
    ///
    /// - Parameters:
    ///   - content: the artifact's `index.html` — a fragment, or a whole document when `full`.
    ///   - themeCSS: `CanvasTheme.tokensCSS()`.
    ///   - runtime: the optional runtimes the artifact needs (`meta.kitRuntime`).
    ///   - full: serve `content` as the document and splice the kit pieces into it.
    ///   - hasKitCSS: whether the artifact has its compiled `kit.css`.
    public nonisolated static func composeKit(
        content: String, themeCSS: String, runtime: [String], full: Bool, hasKitCSS: Bool
    ) -> String {
        let head = kitHead(themeCSS: themeCSS, hasKitCSS: hasKitCSS)
        let bodyEnd = kitBodyEnd(runtime: runtime)
        if full {
            return injectIntoDocument(content, head: head, bodyEnd: bodyEnd)
        }
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>Canvas</title>
        <style>
        \(kitShellCSS)
        </style>
        \(head)</head>
        <body>
        <main id="w42-canvas-content">
        \(content)
        </main>
        \(bodyEnd)</body>
        </html>
        """
    }

    // MARK: - Markdown prose (kit)

    /// Typography for a markdown document on the kit. The kit's preflight strips every element
    /// default, so this restores the whole set — headings, links, lists, code, quotes, tables —
    /// on the Work42 type scale (`--w42-f*`) and label colours, scoped to `.w42-prose`.
    /// It sits in `@layer components`: above the preflight, below utilities, so a utility class on
    /// raw HTML inside a document (`text-sm`, `rounded-card`) still overrides it.
    public nonisolated static let kitProseCSS = """
    @layer components {
      .w42-prose {
        font-size: var(--w42-f13); line-height: 1.55; color: var(--w42-text-primary);
        word-wrap: break-word; overflow-wrap: anywhere;
      }
      .w42-prose > :first-child { margin-top: 0; }
      .w42-prose h1, .w42-prose h2, .w42-prose h3, .w42-prose h4, .w42-prose h5, .w42-prose h6 {
        margin: var(--w42-s16) 0 var(--w42-s4); line-height: 1.25; font-weight: 600; color: var(--w42-text-primary);
      }
      .w42-prose h1 { font-size: var(--w42-f22); font-weight: 700; letter-spacing: -0.02em; margin-bottom: var(--w42-s8); }
      .w42-prose h2 { font-size: var(--w42-f17); letter-spacing: -0.01em; }
      .w42-prose h3 { font-size: var(--w42-f15); margin-top: var(--w42-s12); }
      .w42-prose h4 { font-size: var(--w42-f13); margin-top: var(--w42-s8); margin-bottom: 0; }
      .w42-prose h5, .w42-prose h6 { font-size: var(--w42-f12); margin-top: var(--w42-s8); margin-bottom: 0; color: var(--w42-text-secondary); }
      .w42-prose p { margin: 0 0 var(--w42-s12); }
      .w42-prose strong, .w42-prose b { font-weight: 600; }
      .w42-prose em, .w42-prose i { font-style: italic; }
      .w42-prose a { color: var(--w42-primary); text-decoration: none; }
      .w42-prose a:hover { text-decoration: underline; }
      .w42-prose ul, .w42-prose ol { margin: 0 0 var(--w42-s12); padding-left: 1.6em; }
      .w42-prose ul { list-style: disc; }
      .w42-prose ol { list-style: decimal; }
      .w42-prose ul ul, .w42-prose ol ul { list-style: circle; }
      .w42-prose li { margin: var(--w42-s4) 0; }
      .w42-prose li > ul, .w42-prose li > ol { margin-bottom: 0; }
      .w42-prose li.task-list-item { list-style: none; margin-left: -1.3em; }
      .w42-prose li.task-list-item input { margin-right: 0.5em; }
      .w42-prose img { max-width: 100%; height: auto; }
      .w42-prose code, .w42-prose kbd, .w42-prose samp { font-family: var(--w42-font-mono); font-size: var(--w42-f12); }
      .w42-prose :not(pre) > code {
        padding: 0.1em 0.35em; border-radius: 4px; background: var(--w42-chip-fill);
      }
      .w42-prose kbd {
        padding: 1px 5px; border-radius: 4px; font-size: var(--w42-f10); font-weight: 500;
        color: var(--w42-text-secondary); background: var(--w42-chip-fill); box-shadow: inset 0 0 0 0.5px var(--w42-separator);
      }
      .w42-prose pre {
        margin: 0 0 var(--w42-s12); padding: var(--w42-s12) var(--w42-s16); overflow: auto;
        border-radius: var(--w42-r-card); background: var(--w42-chip-fill); box-shadow: inset 0 0 0 0.5px var(--w42-separator);
        font-size: var(--w42-f12); line-height: 1.5;
      }
      .w42-prose pre code { padding: 0; background: none; font-size: inherit; }
      .w42-prose blockquote {
        margin: 0 0 var(--w42-s12); padding: 0 0 0 var(--w42-s12);
        border-left: 3px solid var(--w42-separator); color: var(--w42-text-secondary);
      }
      .w42-prose blockquote > :last-child { margin-bottom: 0; }
      .w42-prose hr { margin: var(--w42-s16) 0; border: 0; border-top: 0.5px solid var(--w42-separator); }
      .w42-prose table {
        display: block; max-width: 100%; overflow-x: auto; margin: 0 0 var(--w42-s12);
        border-collapse: collapse; font-size: var(--w42-f12);
      }
      .w42-prose th, .w42-prose td { padding: 6px 12px; text-align: left; border-bottom: 0.5px solid var(--w42-separator); }
      .w42-prose th { font-weight: 500; color: var(--w42-text-secondary); }
      .w42-prose tr:last-child td { border-bottom: 0; }
    }
    """

    // MARK: - Document splice

    /// Splices `head` before the first `</head>` and `bodyEnd` before the first
    /// `</body>` (case-insensitive) of an agent-authored document, so a full-document
    /// artifact still lands on the app theme and surfaces JS errors. A missing tag
    /// gets its fragment appended at the end (browsers tolerate trailing
    /// `<style>` / `<script>`).
    public nonisolated static func injectIntoDocument(_ document: String, head: String, bodyEnd: String) -> String {
        var result = insert(head, before: "</head>", in: document)
        result = insert(bodyEnd, before: "</body>", in: result)
        if result.range(of: "</head>", options: .caseInsensitive) == nil && !result.contains(head) {
            result += "\n" + head
        }
        if result.range(of: "</body>", options: .caseInsensitive) == nil && !result.contains(bodyEnd) {
            result += "\n" + bodyEnd
        }
        return result
    }

    private nonisolated static func insert(_ fragment: String, before tag: String, in source: String) -> String {
        guard let range = source.range(of: tag, options: .caseInsensitive) else { return source }
        var result = source
        result.replaceSubrange(range, with: fragment + String(source[range]))
        return result
    }
}

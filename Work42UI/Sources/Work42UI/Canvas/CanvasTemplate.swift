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
// the `@MainActor CanvasTheme.css()` itself) and can be invoked freely
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
    /// request path (mirroring how it caches `CanvasTheme.css()`).
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
        guard let url = Bundle.module.url(
            forResource: "w42-components", withExtension: "css"
        ), let css = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return css
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

    /// The **shared prose stylesheet** — the single source of truth for
    /// markdown-to-HTML text styling. It defines exactly the typography the
    /// spec uses (body 15px / 1.65 line-height, em-sized headings with h1/h2
    /// rules, code, pre, tables, lists, blockquotes, hr, img) but drives every
    /// COLOR from the `--w42-*` design tokens, so a theme change flows through
    /// automatically and the app + spec + artifacts stay visually identical.
    ///
    /// Scoped to `.w42-prose`: apply that class to the spec `<body>` and the
    /// artifact content mount so both render prose the same way. Kept in sync
    /// with `MarkdownDocumentTemplate` (which includes this verbatim).
    public nonisolated static let proseCSS = """
    /* Container: strong enough (a class) to set the base size/color over `body`. */
    .w42-prose {
      font-size: var(--w42-f13, 15px);
      line-height: 1.65;
      color: var(--w42-text-primary);
      word-wrap: break-word;
      overflow-wrap: anywhere;
    }
    /* Element rules are wrapped in :where() so they carry ZERO specificity from
       the scope — the component classes (.w42-table, .w42-code-block, …) always
       win when applied to the same element inside prose. */
    :where(.w42-prose) > :first-child { margin-top: 0; }
    :where(.w42-prose) a { color: var(--w42-primary); text-decoration: none; }
    :where(.w42-prose) a:hover { text-decoration: underline; }
    :where(.w42-prose) h1, :where(.w42-prose) h2, :where(.w42-prose) h3,
    :where(.w42-prose) h4, :where(.w42-prose) h5, :where(.w42-prose) h6 {
      color: var(--w42-text-primary);
      font-weight: 600;
      line-height: 1.3;
      margin: 1.4em 0 0.5em;
    }
    :where(.w42-prose) h1 { font-size: 1.7em; padding-bottom: .3em; border-bottom: 1px solid var(--w42-elevated); }
    :where(.w42-prose) h2 { font-size: 1.4em; padding-bottom: .25em; border-bottom: 1px solid var(--w42-elevated); }
    :where(.w42-prose) h3 { font-size: 1.2em; }
    :where(.w42-prose) h4 { font-size: 1.05em; }
    :where(.w42-prose) p { margin: 0 0 0.9em; }
    :where(.w42-prose) ul, :where(.w42-prose) ol { margin: 0 0 0.9em; padding-left: 1.6em; }
    :where(.w42-prose) li { margin: 0.2em 0; }
    :where(.w42-prose) li.task-list-item { list-style: none; margin-left: -1.3em; }
    :where(.w42-prose) li.task-list-item input { margin-right: 0.5em; }
    :where(.w42-prose) blockquote {
      margin: 0 0 0.9em; padding: 0.2em 0.9em;
      border-left: 3px solid var(--w42-elevated); color: var(--w42-text-secondary);
    }
    :where(.w42-prose) code {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 0.88em;
      background: var(--w42-surface);
      color: var(--w42-text-primary);
      padding: 0.15em 0.35em;
      border-radius: var(--w42-r-input, 6px);
    }
    :where(.w42-prose) pre {
      background: var(--w42-surface);
      border: 1px solid var(--w42-elevated);
      border-radius: var(--w42-r-card, 8px);
      padding: 12px 14px; overflow: auto; margin: 0 0 0.9em;
    }
    :where(.w42-prose) pre code { background: transparent; padding: 0; font-size: 0.85em; color: var(--w42-text-primary); }
    :where(.w42-prose) img { max-width: 100%; height: auto; border-radius: var(--w42-r-input, 6px); }
    :where(.w42-prose) hr { border: none; border-top: 1px solid var(--w42-elevated); margin: 1.6em 0; }
    :where(.w42-prose) table { border-collapse: collapse; margin: 0 0 0.9em; display: block; overflow: auto; }
    :where(.w42-prose) th, :where(.w42-prose) td { border: 1px solid var(--w42-elevated); padding: 6px 12px; }
    :where(.w42-prose) th { background: var(--w42-surface); font-weight: 600; }
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

    /// The **component runtime**: upgrades the agent's bare `<w42-*>` tags into
    /// shared cards (header + right-aligned actions + body) built from the
    /// `w42-component-*` base. Today it handles `<w42-code>` and `<w42-table>`
    /// (the diagram keeps its dedicated `diagramControlsJS`, already migrated onto
    /// the same base classes). Also exposes `window.__w42.theme.apply(tokens)` —
    /// the web side of the reactive-theme bridge the native hosts push into.
    /// Every upgrade is try/catch'd → a `w42-component-error` card on failure
    /// (never a blank/broken render). Bounded self-terminating poll, no
    /// MutationObserver, install-guarded.
    public nonisolated static let componentsJS = """
    (function () {
      "use strict";
      if (window.__w42ComponentsInstalled) { return; }
      window.__w42ComponentsInstalled = true;

      function el(tag, cls, txt) {
        var n = document.createElement(tag);
        if (cls) { n.className = cls; }
        if (txt != null) { n.textContent = txt; }
        return n;
      }
      function mkBtn(label, iconSvg, fn) {
        var b = document.createElement("button");
        b.type = "button";
        b.className = "w42-component-action-btn";
        b.title = label; b.setAttribute("aria-label", label);
        b.innerHTML = iconSvg;
        // `this` inside the handler is the button, so actions can flash feedback.
        b.addEventListener("click", function (e) { e.preventDefault(); e.stopPropagation(); fn.call(b, e); });
        return b;
      }
      var CHECK_ICON = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5 6.5 11.5 12.5 4.5"/></svg>';
      // Momentary success confirmation on an action button ("Copy" -> "✓ Copied").
      function flashDone(btn, label) {
        if (!btn || btn.__w42flash) { return; }
        btn.__w42flash = true;
        var origHTML = btn.innerHTML, origTitle = btn.title;
        btn.innerHTML = CHECK_ICON + '<span class="w42-done-label">' + (label || "Done") + '</span>';
        btn.title = label || "Done";
        btn.classList.add("w42-done");
        setTimeout(function () {
          btn.innerHTML = origHTML; btn.title = origTitle;
          btn.classList.remove("w42-done"); btn.__w42flash = false;
        }, 1400);
      }
      // Build a card: header (title + right actions) + body(bodyNode).
      function buildCard(title, actions, bodyNode, extraClass, icon) {
        var card = el("div", "w42-component-card" + (extraClass ? " " + extraClass : ""));
        var header = el("div", "w42-component-header");
        var left = el("div", "w42-component-left");
        if (icon) { var ic = el("span", "w42-component-icon"); ic.innerHTML = icon; left.appendChild(ic); }
        left.appendChild(el("span", "w42-component-title", title || ""));
        var group = el("div", "w42-component-actions");
        if (actions) { for (var i = 0; i < actions.length; i++) { group.appendChild(mkBtn(actions[i].label, actions[i].icon, actions[i].fn)); } }
        header.appendChild(left); header.appendChild(group);
        var body = el("div", "w42-component-body");
        if (bodyNode) { body.appendChild(bodyNode); }
        card.appendChild(header); card.appendChild(body);
        return { card: card, header: header, body: body };
      }
      // A light/dark scheme toggle for a mockup's embedded runtime: cycles
      // auto -> light -> dark, forcing the iframe's color-scheme so the app
      // (if it honors prefers-color-scheme / ThemeMode.system) reskins live.
      function schemeToggle(iframe) {
        var mode = "auto";
        var btn = mkBtn("App theme: auto", AUTO_ICON, function () {
          mode = (mode === "auto") ? "light" : (mode === "light" ? "dark" : "auto");
          iframe.style.colorScheme = (mode === "auto") ? "normal" : mode;
          btn.innerHTML = (mode === "light") ? SUN_ICON : (mode === "dark" ? MOON_ICON : AUTO_ICON);
          btn.title = "App theme: " + mode;
          btn.classList.toggle("w42-active", mode !== "auto");
        });
        return btn;
      }
      function errorCard(title, message) {
        var parts = buildCard(title || "Error", [], null, "w42-component-error", ERROR_ICON);
        parts.body.textContent = message;
        // Fail loud AND report: every component render failure is console.error'd
        // so the error overlay POSTs it to errors.jsonl — `work42 artifact status`
        // catches broken components mechanically, not by eye.
        if (window.console && console.error) {
          console.error("w42 component error [" + (title || "component") + "]: " + message);
        }
        return parts.card;
      }
      function replace(node, card) {
        if (node.parentNode) { node.parentNode.replaceChild(card, node); }
      }
      var COPY_ICON = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path d="M10.5 5.5V4A1.5 1.5 0 0 0 9 2.5H4A1.5 1.5 0 0 0 2.5 4v5A1.5 1.5 0 0 0 4 10.5h1.5"/></svg>';
      // Mockup runtime scheme toggle: cycles auto (system) / light / dark.
      var SUN_ICON  = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><circle cx="8" cy="8" r="3"/><path d="M8 1v1.7M8 13.3V15M1 8h1.7M13.3 8H15M3.05 3.05l1.2 1.2M11.75 11.75l1.2 1.2M12.95 3.05l-1.2 1.2M4.25 11.75l-1.2 1.2"/></svg>';
      var MOON_ICON = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M13.4 9.6A5.6 5.6 0 0 1 6.4 2.6 5.6 5.6 0 1 0 13.4 9.6z"/></svg>';
      var AUTO_ICON = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="8" cy="8" r="5.5"/><path d="M8 2.5a5.5 5.5 0 0 1 0 11z" fill="currentColor" stroke="none"/></svg>';
      // Component TYPE icons (shown at the start of each card header).
      var CODE_ICON = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M5.5 4.5 2.5 8l3 3.5"/><path d="M10.5 4.5 13.5 8l-3 3.5"/></svg>';
      var TABLE_ICON = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"><rect x="2.5" y="3" width="11" height="10" rx="1.5"/><path d="M2.5 6.5h11M6.5 6.5V13"/></svg>';
      // Flutter brand logo (Flutter light-blue for good contrast in both themes).
      // Flutter logo (shown only for the app= Flutter runner path).
      var MOCKUP_ICON = '<svg viewBox="0 0 24 24" fill="#54C5F8"><path d="M14.314 0L2.3 12 6 15.7 21.684.013h-7.357zm.014 11.072L7.857 17.53l6.47 6.47H21.7l-6.46-6.468 6.46-6.46h-7.37z"/></svg>';
      // Generic device/preview icon (for a plain url= web mockup — no backend).
      var DEVICE_ICON = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"><rect x="4.4" y="1.5" width="7.2" height="13" rx="1.7"/><path d="M6.8 12.5h2.4" stroke-linecap="round"/></svg>';
      var ERROR_ICON = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2.5 14.5 13.5H1.5z"/><path d="M8 6.4v3.2M8 11.7v.01"/></svg>';
      // The 42 brand loader. A 1:1 mirror of the native Loader42 (CoreAnimation):
      // the pencil paints the 4 limb-by-limb, crosses the seam into the 2, then a
      // second lap erases along the same route — a closed loop, invisible restart.
      // strokeStart/strokeEnd are encoded as a normalized 4-part stroke-dasharray
      // "0 s (e-s) (1-e)"; SMIL values/keyTimes/keySplines mirror the CA keyframes
      // 1:1 (same glyph outlines, per-limb widths, windows, cubic-bezier splines).
      // This is THE shared loading indicator for every w42 component.
      var LOADER42_SVG = '<svg class="w42-loader42" viewBox="0 0 256 256" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Loading"><defs><mask id="w42om" maskUnits="userSpaceOnUse" x="0" y="0" width="135" height="256"><path d="M140 77 L104 77 Q90 77 80.4 87.1 L16 155" pathLength="1" fill="none" stroke="#fff" stroke-width="40" stroke-linecap="butt" stroke-linejoin="round" stroke-dasharray="0 0 0 1"><animate attributeName="stroke-dasharray" dur="3.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.0405;0.5;0.5405;1" values="0 0 0 1 ; 0 0 1 0 ; 0 0 1 0 ; 0 1 0 0 ; 0 1 0 0" keySplines="0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0"/></path><path d="M7 153 L126 153" pathLength="1" fill="none" stroke="#fff" stroke-width="26" stroke-linecap="butt" stroke-linejoin="round" stroke-dasharray="0 0 0 1"><animate attributeName="stroke-dasharray" dur="3.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.0405;0.0874;0.5405;0.5874;1" values="0 0 0 1 ; 0 0 0 1 ; 0 0 1 0 ; 0 0 1 0 ; 0 1 0 0 ; 0 1 0 0" keySplines="0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0"/></path><path d="M111 153 L111 188" pathLength="1" fill="none" stroke="#fff" stroke-width="30" stroke-linecap="butt" stroke-linejoin="round" stroke-dasharray="0 0 0 1"><animate attributeName="stroke-dasharray" dur="3.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.0874;0.1049;0.5874;0.6049;1" values="0 0 0 1 ; 0 0 0 1 ; 0 0 1 0 ; 0 0 1 0 ; 0 1 0 0 ; 0 1 0 0" keySplines="0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0"/></path><g clip-path="url(#olean)"><path d="M100 142 L122 96" pathLength="1" fill="none" stroke="#fff" stroke-width="52" stroke-linecap="butt" stroke-linejoin="round" stroke-dasharray="0 0 0 1"><animate attributeName="stroke-dasharray" dur="3.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.1246;0.1589;0.6246;0.6589;1" values="0 0 0 1 ; 0 0 0 1 ; 0 0 1 0 ; 0 0 1 0 ; 0 1 0 0 ; 0 1 0 0" keySplines="0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0"/></path></g></mask><mask id="w42vm" maskUnits="userSpaceOnUse" x="133" y="0" width="123" height="256"><path d="M133 115 L219 115 C236 115 236 77 219 77 L128 77" pathLength="1" fill="none" stroke="#fff" stroke-width="46" stroke-linecap="butt" stroke-linejoin="round" stroke-dasharray="0 0 0 1"><animate attributeName="stroke-dasharray" dur="3.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.1589;0.5;0.6589;1" values="0 0 0 1 ; 0 0 0 1 ; 0 0 1 0 ; 0 0 1 0 ; 0 1 0 0" keySplines="0.0 0.0 1.0 1.0 ; 0.29 0.514 0.645 0.73 ; 0.0 0.0 1.0 1.0 ; 0.29 0.514 0.645 0.73"/></path><path d="M133 152 L254 152" pathLength="1" fill="none" stroke="#fff" stroke-width="46" stroke-linecap="butt" stroke-linejoin="round" stroke-dasharray="0 0 0 1"><animate attributeName="stroke-dasharray" dur="3.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.1589;0.2444;0.6589;0.7444;1" values="0 0 0 1 ; 0 0 0 1 ; 0 0 1 0 ; 0 0 1 0 ; 0 1 0 0 ; 0 1 0 0" keySplines="0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0"/></path></mask><clipPath id="olean"><rect x="0" y="96" width="135" height="46"/></clipPath></defs><path class="w42-l42-shade" d="M50 140 L96 140 L96 128 L80 128 L103 103 L135 103 L135 128 L126 128 L126 188 L96 188 L96 166 L8 166 L7 141 L16 134 L80 64 L135 64 L135 90 L100 90 Z"/><path class="w42-l42-shade" d="M134 64 L222 64 C238 64 249 71 249 87 L249 107 C249 121 240 128 228 128 L134 128 L134 103 L213 103 Q218 103 218 98.5 L218 94.5 Q218 90 213 90 L134 90 Z"/><path class="w42-l42-shade" d="M135 139 L249 139 L249 166 L135 166 Z"/><path class="w42-l42-o w42-l42-mask" d="M50 140 L96 140 L96 128 L80 128 L103 103 L135 103 L135 128 L126 128 L126 188 L96 188 L96 166 L8 166 L7 141 L16 134 L80 64 L135 64 L135 90 L100 90 Z" mask="url(#w42om)"/><g class="w42-l42-mask" mask="url(#w42vm)"><path class="w42-l42-v" d="M134 64 L222 64 C238 64 249 71 249 87 L249 107 C249 121 240 128 228 128 L134 128 L134 103 L213 103 Q218 103 218 98.5 L218 94.5 Q218 90 213 90 L134 90 Z"/><path class="w42-l42-v" d="M135 139 L249 139 L249 166 L135 166 Z"/></g></svg>';
      // Shared loading indicator: the 42 brand loader over an optional caption.
      function buildLoader42(msg) {
        var box = el("div", "w42-loader");
        var mark = el("div", "w42-loader-mark");
        mark.innerHTML = LOADER42_SVG;
        box.appendChild(mark);
        box.appendChild(el("div", "w42-loader-text", msg || ""));
        return box;
      }
      window.__w42 = window.__w42 || {};
      window.__w42.buildLoader = buildLoader42;
      // Per-language brand logos. currentColor for near-black marks so they adapt to the theme.
      var LANG_PATHS = {
        swift:      ["#F05138", "M7.508 0c-.287 0-.573 0-.86.002-.241.002-.483.003-.724.01-.132.003-.263.009-.395.015A9.154 9.154 0 0 0 4.348.15 5.492 5.492 0 0 0 2.85.645 5.04 5.04 0 0 0 .645 2.848c-.245.48-.4.972-.495 1.5-.093.52-.122 1.05-.136 1.576a35.2 35.2 0 0 0-.012.724C0 6.935 0 7.221 0 7.508v8.984c0 .287 0 .575.002.862.002.24.005.481.012.722.014.526.043 1.057.136 1.576.095.528.25 1.02.495 1.5a5.03 5.03 0 0 0 2.205 2.203c.48.244.97.4 1.498.495.52.093 1.05.124 1.576.138.241.007.483.009.724.01.287.002.573.002.86.002h8.984c.287 0 .573 0 .86-.002.241-.001.483-.003.724-.01a10.523 10.523 0 0 0 1.578-.138 5.322 5.322 0 0 0 1.498-.495 5.035 5.035 0 0 0 2.203-2.203c.245-.48.4-.972.495-1.5.093-.52.124-1.05.138-1.576.007-.241.009-.481.01-.722.002-.287.002-.575.002-.862V7.508c0-.287 0-.573-.002-.86a33.662 33.662 0 0 0-.01-.724 10.5 10.5 0 0 0-.138-1.576 5.328 5.328 0 0 0-.495-1.5A5.039 5.039 0 0 0 21.152.645 5.32 5.32 0 0 0 19.654.15a10.493 10.493 0 0 0-1.578-.138 34.98 34.98 0 0 0-.722-.01C17.067 0 16.779 0 16.492 0H7.508zm6.035 3.41c4.114 2.47 6.545 7.162 5.549 11.131-.024.093-.05.181-.076.272l.002.001c2.062 2.538 1.5 5.258 1.236 4.745-1.072-2.086-3.066-1.568-4.088-1.043a6.803 6.803 0 0 1-.281.158l-.02.012-.002.002c-2.115 1.123-4.957 1.205-7.812-.022a12.568 12.568 0 0 1-5.64-4.838c.649.48 1.35.902 2.097 1.252 3.019 1.414 6.051 1.311 8.197-.002C9.651 12.73 7.101 9.67 5.146 7.191a10.628 10.628 0 0 1-1.005-1.384c2.34 2.142 6.038 4.83 7.365 5.576C8.69 8.408 6.208 4.743 6.324 4.86c4.436 4.47 8.528 6.996 8.528 6.996.154.085.27.154.36.213.085-.215.16-.437.224-.668.708-2.588-.09-5.548-1.893-7.992z"],
        dart:       ["#0175C2", "M4.105 4.105S9.158 1.58 11.684.316a3.079 3.079 0 0 1 1.481-.315c.766.047 1.677.788 1.677.788L24 9.948v9.789h-4.263V24H9.789l-9-9C.303 14.5 0 13.795 0 13.105c0-.319.18-.818.316-1.105l3.789-7.895zm.679.679v11.787c.002.543.021 1.024.498 1.508L10.204 23h8.533v-4.263L4.784 4.784zm12.055-.678c-.899-.896-1.809-1.78-2.74-2.643-.302-.267-.567-.468-1.07-.462-.37.014-.87.195-.87.195L6.341 4.105l10.498.001z"],
        javascript: ["#E9BC1C", "M0 0h24v24H0V0zm22.034 18.276c-.175-1.095-.888-2.015-3.003-2.873-.736-.345-1.554-.585-1.797-1.14-.091-.33-.105-.51-.046-.705.15-.646.915-.84 1.515-.66.39.12.75.42.976.9 1.034-.676 1.034-.676 1.755-1.125-.27-.42-.404-.601-.586-.78-.63-.705-1.469-1.065-2.834-1.034l-.705.089c-.676.165-1.32.525-1.71 1.005-1.14 1.291-.811 3.541.569 4.471 1.365 1.02 3.361 1.244 3.616 2.205.24 1.17-.87 1.545-1.966 1.41-.811-.18-1.26-.586-1.755-1.336l-1.83 1.051c.21.48.45.689.81 1.109 1.74 1.756 6.09 1.666 6.871-1.004.029-.09.24-.705.074-1.65l.046.067zm-8.983-7.245h-2.248c0 1.938-.009 3.864-.009 5.805 0 1.232.063 2.363-.138 2.711-.33.689-1.18.601-1.566.48-.396-.196-.597-.466-.83-.855-.063-.105-.11-.196-.127-.196l-1.825 1.125c.305.63.75 1.172 1.324 1.517.855.51 2.004.675 3.207.405.783-.226 1.458-.691 1.811-1.411.51-.93.402-2.07.397-3.346.012-2.054 0-4.109 0-6.179l.004-.056z"],
        typescript: ["#3178C6", "M1.125 0C.502 0 0 .502 0 1.125v21.75C0 23.498.502 24 1.125 24h21.75c.623 0 1.125-.502 1.125-1.125V1.125C24 .502 23.498 0 22.875 0zm17.363 9.75c.612 0 1.154.037 1.627.111a6.38 6.38 0 0 1 1.306.34v2.458a3.95 3.95 0 0 0-.643-.361 5.093 5.093 0 0 0-.717-.26 5.453 5.453 0 0 0-1.426-.2c-.3 0-.573.028-.819.086a2.1 2.1 0 0 0-.623.242c-.17.104-.3.229-.393.374a.888.888 0 0 0-.14.49c0 .196.053.373.156.529.104.156.252.304.443.444s.423.276.696.41c.273.135.582.274.926.416.47.197.892.407 1.266.628.374.222.695.473.963.753.268.279.472.598.614.957.142.359.214.776.214 1.253 0 .657-.125 1.21-.373 1.656a3.033 3.033 0 0 1-1.012 1.085 4.38 4.38 0 0 1-1.487.596c-.566.12-1.163.18-1.79.18a9.916 9.916 0 0 1-1.84-.164 5.544 5.544 0 0 1-1.512-.493v-2.63a5.033 5.033 0 0 0 3.237 1.2c.333 0 .624-.03.872-.09.249-.06.456-.144.623-.25.166-.108.29-.234.373-.38a1.023 1.023 0 0 0-.074-1.089 2.12 2.12 0 0 0-.537-.5 5.597 5.597 0 0 0-.807-.444 27.72 27.72 0 0 0-1.007-.436c-.918-.383-1.602-.852-2.053-1.405-.45-.553-.676-1.222-.676-2.005 0-.614.123-1.141.369-1.582.246-.441.58-.804 1.004-1.089a4.494 4.494 0 0 1 1.47-.629 7.536 7.536 0 0 1 1.77-.201zm-15.113.188h9.563v2.166H9.506v9.646H6.789v-9.646H3.375z"],
        python:     ["#3776AB", "M14.25.18l.9.2.73.26.59.3.45.32.34.34.25.34.16.33.1.3.04.26.02.2-.01.13V8.5l-.05.63-.13.55-.21.46-.26.38-.3.31-.33.25-.35.19-.35.14-.33.1-.3.07-.26.04-.21.02H8.77l-.69.05-.59.14-.5.22-.41.27-.33.32-.27.35-.2.36-.15.37-.1.35-.07.32-.04.27-.02.21v3.06H3.17l-.21-.03-.28-.07-.32-.12-.35-.18-.36-.26-.36-.36-.35-.46-.32-.59-.28-.73-.21-.88-.14-1.05-.05-1.23.06-1.22.16-1.04.24-.87.32-.71.36-.57.4-.44.42-.33.42-.24.4-.16.36-.1.32-.05.24-.01h.16l.06.01h8.16v-.83H6.18l-.01-2.75-.02-.37.05-.34.11-.31.17-.28.25-.26.31-.23.38-.2.44-.18.51-.15.58-.12.64-.1.71-.06.77-.04.84-.02 1.27.05zm-6.3 1.98l-.23.33-.08.41.08.41.23.34.33.22.41.09.41-.09.33-.22.23-.34.08-.41-.08-.41-.23-.33-.33-.22-.41-.09-.41.09zm13.09 3.95l.28.06.32.12.35.18.36.27.36.35.35.47.32.59.28.73.21.88.14 1.04.05 1.23-.06 1.23-.16 1.04-.24.86-.32.71-.36.57-.4.45-.42.33-.42.24-.4.16-.36.09-.32.05-.24.02-.16-.01h-8.22v.82h5.84l.01 2.76.02.36-.05.34-.11.31-.17.29-.25.25-.31.24-.38.2-.44.17-.51.15-.58.13-.64.09-.71.07-.77.04-.84.01-1.27-.04-1.07-.14-.9-.2-.73-.25-.59-.3-.45-.33-.34-.34-.25-.34-.16-.33-.1-.3-.04-.25-.02-.2.01-.13v-5.34l.05-.64.13-.54.21-.46.26-.38.3-.32.33-.24.35-.2.35-.14.33-.1.3-.06.26-.04.21-.02.13-.01h5.84l.69-.05.59-.14.5-.21.41-.28.33-.32.27-.35.2-.36.15-.36.1-.35.07-.32.04-.28.02-.21V6.07h2.09l.14.01zm-6.47 14.25l-.23.33-.08.41.08.41.23.33.33.23.41.08.41-.08.33-.23.23-.33.08-.41-.08-.41-.23-.33-.33-.23-.41-.08-.41.08z"],
        go:         ["#00ADD8", "M1.811 10.231c-.047 0-.058-.023-.035-.059l.246-.315c.023-.035.081-.058.128-.058h4.172c.046 0 .058.035.035.07l-.199.303c-.023.036-.082.07-.117.07zM.047 11.306c-.047 0-.059-.023-.035-.058l.245-.316c.023-.035.082-.058.129-.058h5.328c.047 0 .07.035.058.07l-.093.28c-.012.047-.058.07-.105.07zm2.828 1.075c-.047 0-.059-.035-.035-.07l.163-.292c.023-.035.07-.07.117-.07h2.337c.047 0 .07.035.07.082l-.023.28c0 .047-.047.082-.082.082zm12.129-2.36c-.736.187-1.239.327-1.963.514-.176.046-.187.058-.34-.117-.174-.199-.303-.327-.548-.444-.737-.362-1.45-.257-2.115.175-.795.514-1.204 1.274-1.192 2.22.011.935.654 1.706 1.577 1.835.795.105 1.46-.175 1.987-.77.105-.13.198-.27.315-.434H10.47c-.245 0-.304-.152-.222-.35.152-.362.432-.97.596-1.274a.315.315 0 01.292-.187h4.253c-.023.316-.023.631-.07.947a4.983 4.983 0 01-.958 2.29c-.841 1.11-1.94 1.8-3.33 1.986-1.145.152-2.209-.07-3.143-.77-.865-.655-1.356-1.52-1.484-2.595-.152-1.274.222-2.419.993-3.424.83-1.086 1.928-1.776 3.272-2.02 1.098-.2 2.15-.07 3.096.571.62.41 1.063.97 1.356 1.648.07.105.023.164-.117.2m3.868 6.461c-1.064-.024-2.034-.328-2.852-1.029a3.665 3.665 0 01-1.262-2.255c-.21-1.32.152-2.489.947-3.529.853-1.122 1.881-1.706 3.272-1.95 1.192-.21 2.314-.095 3.33.595.923.63 1.496 1.484 1.648 2.605.198 1.578-.257 2.863-1.344 3.962-.771.783-1.718 1.273-2.805 1.495-.315.06-.63.07-.934.106zm2.78-4.72c-.011-.153-.011-.27-.034-.387-.21-1.157-1.274-1.81-2.384-1.554-1.087.245-1.788.935-2.045 2.033-.21.912.234 1.835 1.075 2.21.643.28 1.285.244 1.905-.07.923-.48 1.425-1.228 1.484-2.233z"],
        kotlin:     ["#7F52FF", "M24 24H0V0h24L12 12Z"],
        html5:      ["#E34F26", "M1.5 0h21l-1.91 21.563L11.977 24l-8.564-2.438L1.5 0zm7.031 9.75l-.232-2.718 10.059.003.23-2.622L5.412 4.41l.698 8.01h9.126l-.326 3.426-2.91.804-2.955-.81-.188-2.11H6.248l.33 4.171L12 19.351l5.379-1.443.744-8.157H8.531z"],
        css3:       ["#1572B6", "M1.5 0h21l-1.91 21.563L11.977 24l-8.565-2.438L1.5 0zm17.09 4.413L5.41 4.41l.213 2.622 10.125.002-.255 2.716h-6.64l.24 2.573h6.182l-.366 3.523-2.91.804-2.956-.81-.188-2.11h-2.61l.29 3.855L12 19.288l5.373-1.53L18.59 4.414z"],
        ruby:       ["#CC342D", "M20.156.083c3.033.525 3.893 2.598 3.829 4.77L24 4.822 22.635 22.71 4.89 23.926h.016C3.433 23.864.15 23.729 0 19.139l1.645-3 2.819 6.586.503 1.172 2.805-9.144-.03.007.016-.03 9.255 2.956-1.396-5.431-.99-3.9 8.82-.569-.615-.51L16.5 2.114 20.159.073l-.003.01zM0 19.089zM5.13 5.073c3.561-3.533 8.157-5.621 9.922-3.84 1.762 1.777-.105 6.105-3.673 9.636-3.563 3.532-8.103 5.734-9.864 3.957-1.766-1.777.045-6.217 3.612-9.75l.003-.003z"],
        php:        ["#8892BF", "M7.01 10.207h-.944l-.515 2.648h.838c.556 0 .97-.105 1.242-.314.272-.21.455-.559.55-1.049.092-.47.05-.802-.124-.995-.175-.193-.523-.29-1.047-.29zM12 5.688C5.373 5.688 0 8.514 0 12s5.373 6.313 12 6.313S24 15.486 24 12c0-3.486-5.373-6.312-12-6.312zm-3.26 7.451c-.261.25-.575.438-.917.551-.336.108-.765.164-1.285.164H5.357l-.327 1.681H3.652l1.23-6.326h2.65c.797 0 1.378.209 1.744.628.366.418.476 1.002.33 1.752a2.836 2.836 0 0 1-.305.847c-.143.255-.33.49-.561.703zm4.024.715l.543-2.799c.063-.318.039-.536-.068-.651-.107-.116-.336-.174-.687-.174H11.46l-.704 3.625H9.388l1.23-6.327h1.367l-.327 1.682h1.218c.767 0 1.295.134 1.586.401s.378.7.263 1.299l-.572 2.944h-1.389zm7.597-2.265a2.782 2.782 0 0 1-.305.847c-.143.255-.33.49-.561.703a2.44 2.44 0 0 1-.917.551c-.336.108-.765.164-1.286.164h-1.18l-.327 1.682h-1.378l1.23-6.326h2.649c.797 0 1.378.209 1.744.628.366.417.477 1.001.331 1.751zM17.766 10.207h-.943l-.516 2.648h.838c.557 0 .971-.105 1.242-.314.272-.21.455-.559.551-1.049.092-.47.049-.802-.125-.995s-.524-.29-1.047-.29z"],
        cplusplus:  ["#00599C", "M22.394 6c-.167-.29-.398-.543-.652-.69L12.926.22c-.509-.294-1.34-.294-1.848 0L2.26 5.31c-.508.293-.923 1.013-.923 1.6v10.18c0 .294.104.62.271.91.167.29.398.543.652.69l8.816 5.09c.508.293 1.34.293 1.848 0l8.816-5.09c.254-.147.485-.4.652-.69.167-.29.27-.616.27-.91V6.91c.003-.294-.1-.62-.268-.91zM12 19.11c-3.92 0-7.109-3.19-7.109-7.11 0-3.92 3.19-7.11 7.11-7.11a7.133 7.133 0 016.156 3.553l-3.076 1.78a3.567 3.567 0 00-3.08-1.78A3.56 3.56 0 008.444 12 3.56 3.56 0 0012 15.555a3.57 3.57 0 003.08-1.778l3.078 1.78A7.135 7.135 0 0112 19.11zm7.11-6.715h-.79v.79h-.79v-.79h-.79v-.79h.79v-.79h.79v.79h.79zm2.962 0h-.79v.79h-.79v-.79h-.79v-.79h.79v-.79h.79v.79h.79z"],
        c:          ["currentColor", "M16.5921 9.1962s-.354-3.298-3.627-3.39c-3.2741-.09-4.9552 2.474-4.9552 6.14 0 3.6651 1.858 6.5972 5.0451 6.5972 3.184 0 3.5381-3.665 3.5381-3.665l6.1041.365s.36 3.31-2.196 5.836c-2.552 2.5241-5.6901 2.9371-7.8762 2.9201-2.19-.017-5.2261.034-8.1602-2.97-2.938-3.0101-3.436-5.9302-3.436-8.8002 0-2.8701.556-6.6702 4.047-9.5502C7.444.72 9.849 0 12.254 0c10.0422 0 10.7172 9.2602 10.7172 9.2602z"]
      };
      function langIcon(lang) {
        var key = (lang || "").toLowerCase();
        var alias = { js: "javascript", jsx: "javascript", ts: "typescript", tsx: "typescript", py: "python", "c++": "cplusplus", cpp: "cplusplus", cxx: "cplusplus", cc: "cplusplus", htm: "html5", html: "html5", css: "css3", rb: "ruby", kt: "kotlin", golang: "go" };
        if (alias[key]) { key = alias[key]; }
        var e = LANG_PATHS[key];
        if (!e) { return CODE_ICON; }
        return '<svg viewBox="0 0 24 24" fill="' + e[0] + '"><path d="' + e[1] + '"/></svg>';
      }

      // ---- Flutter mockup: device profiles + native seam ----
      var fmSeq = 0;
      // insetTop/insetBottom (device px, scaled with the frame) reserve the real
      // safe areas — status bar + home indicator — so the embedded app sits INSIDE
      // the screen like on a real device. platform picks the status-bar + indicator style.
      var DEVICES = {
        "iphone-16-pro": { label: "iPhone 16 Pro", w: 402, h: 874,  radius: 55, chrome: "island", platform: "ios",     insetTop: 54, insetBottom: 34 },
        "iphone-15":     { label: "iPhone 15",     w: 393, h: 852,  radius: 52, chrome: "island", platform: "ios",     insetTop: 50, insetBottom: 34 },
        "pixel-7":       { label: "Pixel 7",       w: 412, h: 915,  radius: 30, chrome: "punch",  platform: "android", insetTop: 32, insetBottom: 24 },
        "ipad-11":       { label: "iPad 11",       w: 834, h: 1194, radius: 22, chrome: "none",   platform: "ipados",  insetTop: 24, insetBottom: 20 },
        "web":           { label: "Web",           w: 1280, h: 800, radius: 8,  chrome: "none",   platform: "web",     insetTop: 0,  insetBottom: 0 }
      };
      var DEVICE_ORDER = ["iphone-16-pro", "iphone-15", "pixel-7", "ipad-11", "web"];
      // Status-bar glyphs (white, drawn in the top safe area). Signal + wifi + battery.
      var SB_SIGNAL  = '<svg viewBox="0 0 18 12" fill="#fff"><rect x="0" y="8" width="3" height="4" rx="0.7"/><rect x="5" y="5.5" width="3" height="6.5" rx="0.7"/><rect x="10" y="3" width="3" height="9" rx="0.7"/><rect x="15" y="0.5" width="3" height="11.5" rx="0.7"/></svg>';
      var SB_WIFI    = '<svg viewBox="0 0 16 12" fill="#fff"><path d="M8 11.2 5.9 8.6a3.3 3.3 0 0 1 4.2 0L8 11.2zM3.7 5.9 2 3.8a9.3 9.3 0 0 1 12 0l-1.7 2.1a6.6 6.6 0 0 0-8.6 0z"/></svg>';
      var SB_BATTERY = '<svg viewBox="0 0 26 12" fill="none"><rect x="0.6" y="0.6" width="21" height="10.8" rx="2.6" stroke="#fff" stroke-opacity="0.55" stroke-width="1"/><rect x="2.2" y="2.2" width="17" height="7.6" rx="1.4" fill="#fff"/><path d="M23.4 4.2v3.6a2 2 0 0 0 0-3.6z" fill="#fff" fill-opacity="0.55"/></svg>';
      function statusBarHTML(time) {
        return '<div class="w42-mockup-sb-time">' + time + '</div>' +
               '<div class="w42-mockup-sb-icons">' + SB_SIGNAL + SB_WIFI + SB_BATTERY + '</div>';
      }
      var FM_HANDLER = "w42FlutterMockup";
      function fmPost(msg) {
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[FM_HANDLER]) {
            window.webkit.messageHandlers[FM_HANDLER].postMessage(msg);
          }
        } catch (e) {}
      }
      // Per-mockup callback registry + the native-to-page dispatch API. Native
      // resolves `app` to a served Flutter-web URL and calls ready(id, url).
      window.__w42FM = window.__w42FM || { _cbs: {} };
      window.__w42FlutterMockup = {
        ready: function (id, url) { var c = window.__w42FM._cbs[id]; if (c && c.ready) { c.ready(url); } },
        error: function (id, msg) { var c = window.__w42FM._cbs[id]; if (c && c.error) { c.error(msg); } },
        reload: function (id) { var c = window.__w42FM._cbs[id]; if (c && c.reload) { c.reload(); } }
      };

      // <w42-code lang="swift" title="…">source</w42-code>
      function upgradeCode(node) {
        var lang = (node.getAttribute("lang") || node.getAttribute("language") || "").trim();
        var title = node.getAttribute("title") || (lang || "Code");
        var source = (node.textContent || "").replace(/^\\n/, "").replace(/\\s+$/, "");
        var pre = el("pre");
        var code = el("code");
        if (lang) { code.className = "language-" + lang; }
        code.textContent = source;
        pre.appendChild(code);
        var actions = [{ label: "Copy", icon: COPY_ICON, fn: function () {
          try { if (navigator.clipboard) { navigator.clipboard.writeText(code.textContent); } } catch (e) {}
          flashDone(this, "Copied");
        } }];
        replace(node, buildCard(title, actions, pre, null, langIcon(lang)).card);
        // highlight.js (injected right after this runtime) colors the new pre>code.
      }

      // <w42-table title="…" data-rows='[["A","B"],[1,2]]'> or inner <tr>/<td>
      function upgradeTable(node) {
        var title = node.getAttribute("title") || "Table";
        var table = el("table", "w42-table");
        var dataRows = node.getAttribute("data-rows");
        if (dataRows) {
          var rows;
          try { rows = JSON.parse(dataRows); }
          catch (e) { replace(node, errorCard(title, "w42-table: invalid data-rows JSON\\n" + e.message)); return; }
          if (rows && rows.length) {
            var thead = el("thead"); var htr = el("tr"); var hr = rows[0] || [];
            for (var c = 0; c < hr.length; c++) { htr.appendChild(el("th", null, String(hr[c]))); }
            thead.appendChild(htr); table.appendChild(thead);
            var tbody = el("tbody");
            for (var r = 1; r < rows.length; r++) {
              var tr = el("tr"); var row = rows[r] || [];
              for (var k = 0; k < row.length; k++) { tr.appendChild(el("td", null, String(row[k]))); }
              tbody.appendChild(tr);
            }
            table.appendChild(tbody);
          }
        } else {
          var inner = node.querySelectorAll("tr");
          if (inner.length) {
            var tb = el("tbody");
            for (var j = 0; j < inner.length; j++) { tb.appendChild(inner[j].cloneNode(true)); }
            table.appendChild(tb);
          }
        }
        replace(node, buildCard(title, [], table, null, TABLE_ICON).card);
      }

      // A generic device-framed web mockup — the body is just an iframe pointing
      // at a URL. Two ways to supply that URL:
      //   <w42-mockup url="https://…" device="iphone-16-pro" title="…">  — embed ANY
      //     web URL directly (Vercel/Storybook/dev-server/prototype); no backend.
      //   <w42-mockup app="/path/to/flutter" device="…">  — the Flutter convenience
      //     path: the native runner compiles the project to web and hands back a URL.
      // (`<w42-flutter-mockup>` is a back-compat alias for the same upgrader.)
      // Renders a card with a device picker + a device-framed iframe scaled to fit.
      function upgradeMockup(node) {
        var title = node.getAttribute("title") || "Mockup";
        var url = node.getAttribute("url") || "";
        var app = node.getAttribute("app") || "";
        var deviceKey = node.getAttribute("device") || "iphone-16-pro";
        if (!DEVICES[deviceKey]) { deviceKey = "iphone-16-pro"; }
        var id = "w42fm-" + (++fmSeq);

        var picker = el("select", "w42-mockup-picker");
        for (var di = 0; di < DEVICE_ORDER.length; di++) {
          var k = DEVICE_ORDER[di];
          var opt = el("option", null, DEVICES[k].label);
          opt.value = k;
          if (k === deviceKey) { opt.selected = true; }
          picker.appendChild(opt);
        }

        var scaler = el("div", "w42-mockup-scaler");
        var frame = el("div", "w42-mockup-frame");
        // Top safe area: the OS status bar (time + signal/wifi/battery).
        var statusbar = el("div", "w42-mockup-statusbar");
        statusbar.innerHTML = statusBarHTML("9:41");
        // The screen: the embedded app, inset between the two safe areas.
        var screen = el("div", "w42-mockup-screen");
        var iframe = document.createElement("iframe");
        iframe.className = "w42-mockup-iframe";
        iframe.setAttribute("frameborder", "0");
        iframe.setAttribute("sandbox", "allow-scripts allow-same-origin allow-forms allow-popups allow-modals");
        screen.appendChild(iframe);
        // Bottom safe area: the home indicator / gesture bar.
        var home = el("div", "w42-mockup-home");
        home.appendChild(el("div", "w42-mockup-home-bar"));
        var chrome = el("div", "w42-mockup-chrome");  // Dynamic Island / punch overlay
        frame.appendChild(statusbar);
        frame.appendChild(screen);
        frame.appendChild(home);
        frame.appendChild(chrome);
        scaler.appendChild(frame);
        var status = el("div", "w42-mockup-status");
        var loading = buildLoader42("");
        loading.className = "w42-loader w42-mockup-loading";
        loading.style.display = "none";
        var stage = el("div", "w42-mockup-stage");
        stage.appendChild(scaler);
        stage.appendChild(loading);
        stage.appendChild(status);

        // Flutter logo only for the Flutter runner path; generic device icon for url=.
        var parts = buildCard(title, [], stage, null, app ? MOCKUP_ICON : DEVICE_ICON);
        var actions = parts.header.querySelector(".w42-component-actions");
        if (actions) {
          // Preview the embedded app in light/dark (themes the iframe, not the card).
          actions.appendChild(schemeToggle(iframe));
          actions.appendChild(picker);
        }

        function sizeFrame() {
          var d = DEVICES[picker.value] || DEVICES[deviceKey];
          frame.style.width = d.w + "px";
          frame.style.height = d.h + "px";
          frame.style.borderRadius = (d.radius || 20) + "px";
          frame.className = "w42-mockup-frame w42-mockup-" + (d.platform || "web");
          chrome.className = "w42-mockup-chrome w42-mockup-chrome-" + (d.chrome || "none");
          // Reserve the real safe areas (0 on web → strips collapse).
          statusbar.style.height = (d.insetTop || 0) + "px";
          home.style.height = (d.insetBottom || 0) + "px";
          statusbar.style.display = (d.insetTop ? "flex" : "none");
          home.style.display = (d.insetBottom ? "flex" : "none");
          var avail = (stage.clientWidth || parts.body.clientWidth || 0) - 8;
          var scale = (avail > 0 && avail < d.w) ? (avail / d.w) : 1;
          scaler.style.transform = "scale(" + scale + ")";
          scaler.style.width = d.w + "px";
          scaler.style.height = d.h + "px";
          stage.style.height = (d.h * scale + 16) + "px";
        }
        function setURL(u) { if (u) { iframe.src = u; status.style.display = "none"; loading.style.display = "none"; } }
        function setStatus(msg, isErr) {
          status.textContent = msg;
          status.style.display = msg ? "block" : "none";
          status.className = "w42-mockup-status" + (isErr ? " w42-mockup-status-error" : "");
          loading.style.display = "none";
        }
        function showLoading(msg) {
          var t = loading.querySelector(".w42-loader-text");
          if (t) { t.textContent = msg; }
          loading.style.display = "flex";
          status.style.display = "none";
        }

        picker.addEventListener("change", function () {
          sizeFrame();
          if (app && !url) { fmPost({ type: "device", id: id, device: picker.value }); }
        });
        window.addEventListener("resize", sizeFrame);

        replace(node, parts.card);
        setTimeout(sizeFrame, 0);

        var started = false;
        function startBuild() {
          if (started) { return; }
          started = true;
          showLoading("Setting up your Flutter mockup\\u2026");
          window.__w42FM._cbs[id] = {
            ready: function (u) { setURL(u); },
            error: function (m) { setStatus(m || "Build failed", true); },
            reload: function () { if (iframe.src) { var s = iframe.src; iframe.src = "about:blank"; iframe.src = s; } }
          };
          fmPost({ type: "start", id: id, app: app, device: picker.value });
        }

        if (url) {
          setURL(url);
        } else if (app) {
          // Spawn the Flutter run ONLY when the mockup scrolls into view (lazy).
          if (typeof IntersectionObserver !== "undefined") {
            var io = new IntersectionObserver(function (entries) {
              for (var vi = 0; vi < entries.length; vi++) {
                if (entries[vi].isIntersecting) { io.disconnect(); startBuild(); break; }
              }
            }, { threshold: 0.05 });
            io.observe(parts.card);
          } else {
            startBuild();
          }
        } else {
          setStatus("Set a url= or app= attribute", true);
        }
      }

      var UPGRADERS = { "w42-code": upgradeCode, "w42-table": upgradeTable, "w42-mockup": upgradeMockup, "w42-flutter-mockup": upgradeMockup };
      function scan() {
        for (var tag in UPGRADERS) {
          if (!Object.prototype.hasOwnProperty.call(UPGRADERS, tag)) { continue; }
          var nodes = document.querySelectorAll(tag);
          for (var i = 0; i < nodes.length; i++) {
            var n = nodes[i];
            if (n.getAttribute("data-w42-upgraded")) { continue; }
            n.setAttribute("data-w42-upgraded", "1");
            try { UPGRADERS[tag](n); }
            catch (err) {
              // errorCard() reports to the overlay sink (errors.jsonl) itself.
              try { replace(n, errorCard(tag, String((err && err.message) || err))); } catch (e2) {}
            }
          }
        }
      }
      var ticks = 0;
      function tick() { scan(); if (++ticks < 40) { setTimeout(tick, 500); } }

      // Reactive-theme bridge (web side): native hosts push token updates here.
      var theme = {
        apply: function (tokens) {
          if (!tokens) { return; }
          try {
            var root = document.documentElement;
            for (var k in tokens) {
              if (!Object.prototype.hasOwnProperty.call(tokens, k)) { continue; }
              var name = (k.indexOf("--") === 0) ? k : ("--w42-" + k);
              root.style.setProperty(name, String(tokens[k]));
            }
          } catch (e) { if (window.console && console.error) { console.error("w42 theme.apply:", e); } }
          // A :root var swap reskins CSS-driven chrome live, but a rendered
          // mermaid SVG baked its colours in — re-run mermaid so diagrams track
          // the new palette too. No-op when the page has no diagrams.
          try {
            if (window.__w42 && window.__w42.mermaid
                && typeof window.__w42.mermaid.rerender === "function") {
              window.__w42.mermaid.rerender();
            }
          } catch (e2) {}
        }
      };

      window.__w42 = window.__w42 || {};
      window.__w42.theme = theme;
      window.__w42.upgrade = scan;

      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", tick);
      } else { tick(); }
    })();
    """

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
      border: 1px solid var(--w42-elevated, rgba(120,120,128,0.28));
      border-radius: var(--w42-r-card, 10px);
      background: var(--w42-surface, #ffffff);
      overflow: hidden;
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
      height: 46px;
      padding: 0 10px 0 14px;
      box-sizing: border-box;
      background: var(--w42-elevated, rgba(120, 120, 128, 0.07));
      border-bottom: 1px solid var(--w42-elevated, rgba(120, 120, 128, 0.18));
      -webkit-backdrop-filter: saturate(180%) blur(8px);
      backdrop-filter: saturate(180%) blur(8px);
      font-family: var(--w42-font-family, -apple-system, BlinkMacSystemFont, system-ui, sans-serif);
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
      color: var(--w42-text-secondary, #6b6b70);
    }
    .w42-component-icon svg,
    .w42-diagram-header .w42-dh-icon svg { width: 100%; height: 100%; display: block; }
    .w42-component-title,
    .w42-diagram-header .w42-dh-title {
      font-size: 14px;
      font-weight: 600;
      color: var(--w42-text-primary, #1a1a1a);
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
      border-radius: 7px;
      cursor: pointer;
      /* Higher contrast: a subtle always-on chip + strong icon color, so the
         buttons clearly read as interactive controls (not faint glyphs). */
      color: var(--w42-text-primary, #1a1a1a);
      background: rgba(127, 127, 127, 0.12);
      box-shadow: inset 0 0 0 1px rgba(127, 127, 127, 0.10);
      transition: background 0.12s ease, color 0.12s ease, box-shadow 0.12s ease;
    }
    .w42-component-action-btn:hover,
    .w42-diagram-header .w42-dh-btn:hover {
      background: rgba(127, 127, 127, 0.22);
      box-shadow: inset 0 0 0 1px rgba(127, 127, 127, 0.18);
    }
    .w42-component-action-btn:active,
    .w42-diagram-header .w42-dh-btn:active {
      background: rgba(127, 127, 127, 0.30);
    }
    .w42-component-action-btn svg,
    .w42-diagram-header .w42-dh-btn svg {
      width: 18px;
      height: 18px;
      display: block;
    }
    /* Active state for the mockup's app-theme toggle. */
    .w42-component-action-btn.w42-active {
      color: var(--w42-accent, #0a84ff);
      background: color-mix(in srgb, var(--w42-accent, #0a84ff) 14%, transparent);
      box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--w42-accent, #0a84ff) 30%, transparent);
    }
    /* Momentary "✓ Copied" confirmation — the button widens to show the label. */
    .w42-component-action-btn.w42-done {
      width: auto;
      padding: 0 10px;
      color: var(--w42-green, #34c759);
      background: color-mix(in srgb, var(--w42-green, #34c759) 15%, transparent);
      box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--w42-green, #34c759) 32%, transparent);
    }
    .w42-done-label { font: 600 12px var(--w42-font-family, -apple-system, system-ui, sans-serif); }
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
      color: var(--w42-red, #d24b4b);
      font-family: ui-monospace, "SF Mono", Menlo, Monaco, monospace;
      font-size: 12px;
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
      font: 600 12px var(--w42-font-family, -apple-system, system-ui, sans-serif);
      color: var(--w42-text-primary, #1a1a1a);
      /* A visible chevron caret + a chip background so it clearly reads as a choice.
         Height matches the action buttons (30px) so the header controls align;
         line-height matches height so the (appearance:none) select text centers. */
      height: 30px;
      line-height: 30px;
      background-color: rgba(127, 127, 127, 0.12);
      background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6' fill='none' stroke='%238a8a8f' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M1 1l4 4 4-4'/%3E%3C/svg%3E");
      background-repeat: no-repeat;
      background-position: right 9px center;
      box-shadow: inset 0 0 0 1px rgba(127, 127, 127, 0.20);
      border-radius: 7px;
      padding: 0 26px 0 11px;
      transition: background-color 0.12s ease, box-shadow 0.12s ease;
    }
    .w42-mockup-picker:hover {
      background-color: rgba(127, 127, 127, 0.22);
      box-shadow: inset 0 0 0 1px rgba(127, 127, 127, 0.30);
    }
    .w42-mockup-picker:focus-visible {
      box-shadow: inset 0 0 0 2px var(--w42-accent, #0a84ff);
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
      font: 500 13px var(--w42-font-family, -apple-system, system-ui, sans-serif);
      color: var(--w42-text-secondary, #6b6b70);
      background: var(--w42-surface, #fff);
      padding: 8px 14px; border-radius: 8px;
      border: 1px solid var(--w42-elevated, rgba(120,120,128,0.2));
    }
    .w42-mockup-status-error { color: var(--w42-red, #d24b4b); }
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
    /// the `--w42-*` custom properties emitted by `CanvasTheme.css()`
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

    /// Composes a complete, theme-matched HTML document from an agent
    /// content fragment.
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
    /// `_w42/w42-components.css` relative to every artifact root.
    ///
    /// - Parameters:
    ///   - content: the agent's HTML fragment (rendered as markup as-is).
    ///   - themeCSS: the theme stylesheet to inline, normally the output
    ///     of `CanvasTheme.css()`.
    /// - Returns: a complete `<!doctype html>` document string.
    public nonisolated static func compose(content: String, themeCSS: String) -> String {
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
        <link rel="stylesheet" href="_w42/w42-components.css">
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
        <script>
        \(componentsJS)
        </script>
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
}

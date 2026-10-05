// MarkdownDocumentTemplate.swift - Wraps a cmark HTML fragment in a themed
// full document for MarkdownWebView. Transparent background (the tile provides
// the surface), readable typography, light/dark palettes, and browser-native
// text selection.

import Foundation

enum MarkdownDocumentTemplate {

    /// Active-theme accent RGB (0–255) so links, text selection, and comment
    /// marks match the app's primary color instead of a fixed browser blue.
    struct Accent {
        let r: Int, g: Int, b: Int
        func rgba(_ alpha: Double) -> String { "rgba(\(r),\(g),\(b),\(alpha))" }
        var rgb: String { "rgb(\(r),\(g),\(b))" }
    }

    /// Compose a full HTML document around `fragment`, styled for `dark`/light.
    /// `accent` supplies the active primary color for links, selection, and
    /// comment marks; `commentsEnabled` adds the comment-layer CSS (marks + floating
    /// add button) — off for read-only surfaces (spec/meeting/menu previews).
    /// `injectArtifactBridge` adds the CSS + JS needed to convert
    /// `.w42-artifact-ref` divs (emitted by `MarkdownArtifactRewriter`) into
    /// live auto-sized iframes pointing at the ArtifactServer.
    static func compose(
        fragment: String,
        dark: Bool,
        accent: Accent,
        commentsEnabled: Bool = false,
        injectArtifactBridge: Bool = false
    ) -> String {
        // Accent-tinted selection: stronger in dark, softer in light.
        let selection = accent.rgba(dark ? 0.34 : 0.24)
        let commentCSS = commentsEnabled ? Self.commentCSS(accent: accent, dark: dark) : ""
        let artifactCSS = injectArtifactBridge ? Self.artifactBridgeCSS(dark: dark) : ""
        let artifactScript = injectArtifactBridge
            ? "<script>\n\(Self.artifactBridgeScript)\n</script>"
            : ""
        // Inject the SAME --w42-* custom properties the artifact/canvas system
        // exposes (CanvasTheme.css(), sourced from the DT design tokens) so any
        // content composed into a markdown document — including content this
        // template's caller injects as trailingHTML/raw-HTML substitutions
        // (FlowHTMLRenderer, TestingPlanFlowsHTML, the QA report augmenter) —
        // can reference the real, single-source-of-truth tokens (var(--w42-f11),
        // var(--w42-s8), var(--w42-green), …) instead of a second hand-picked
        // palette. The document keeps its existing Palette-based rules except
        // that hyperlinks intentionally consume the shared primary token.
        let designTokenCSS = CanvasTheme.css()
        // Inline the component library (rather than the artifact server's
        // `_w42/w42-components.css` link, which a file:// spec doc can't reach)
        // so spec-embedded HTML — trailing components, raw HTML — uses the same
        // `.w42-*` classes as artifacts.
        let componentCSS = CanvasTemplate.componentLibraryCSS()
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(designTokenCSS)
        :root { color-scheme: \(dark ? "dark" : "light"); }
        * { box-sizing: border-box; }
        html, body { margin: 0; padding: 0; background: transparent; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
          padding: 16px 22px 40px;
          -webkit-user-select: text;
          user-select: text;
        }
        </style>
        <style>
        \(componentCSS)
        </style>
        <style>
        /* Shared prose typography — the single source of truth, identical to
           the artifacts and driven by the --w42-* theme tokens. */
        \(CanvasTemplate.proseCSS)
        ::selection { background: \(selection); }
        \(commentCSS)
        \(artifactCSS)
        \(CanvasTemplate.diagramControlsCSS)
        \(CanvasTemplate.highlightCSS)
        </style>
        </head>
        <body class="w42-md w42-prose">
        \(fragment)
        <script>
        \(CanvasTemplate.mermaidJS(src: MarkdownImageRewriter.mermaidScriptURL))
        </script>
        <script>
        \(CanvasTemplate.componentsJS)
        </script>
        <script>
        \(CanvasTemplate.highlightJS(src: MarkdownImageRewriter.highlightScriptURL))
        </script>
        <script>
        \(CanvasTemplate.diagramControlsJS)
        </script>
        \(artifactScript)
        </body>
        </html>
        """
    }

    /// CSS for the Preview comment layer: an accent left-border + subtle tint on
    /// commented blocks, a clickable marker dot, and the floating "add comment"
    /// button that appears next to a live text selection. Mirrors the native
    /// editor gutter affordance, adapted to flowed HTML (block granularity).
    private static func commentCSS(accent: Accent, dark: Bool) -> String {
        """
        .w42-commented {
          background: \(accent.rgba(dark ? 0.10 : 0.08));
          box-shadow: inset 3px 0 0 \(accent.rgb);
          border-radius: 3px;
        }
        .w42-comment-marker {
          position: absolute;
          left: -18px;
          width: 14px; height: 14px;
          margin-top: 0.2em;
          border-radius: 50%;
          background: \(accent.rgb);
          color: #fff;
          font-size: 10px;
          line-height: 14px;
          text-align: center;
          cursor: pointer;
          user-select: none;
          -webkit-user-select: none;
          box-shadow: 0 1px 3px rgba(0,0,0,0.35);
        }
        .w42-comment-host { position: relative; }
        /* Gutter-style "+" affordance in the left margin, mirroring the file
           editor's gutter "+" — a small accent circle at the start of the
           selection, not a floating pill. */
        #w42-add {
          position: fixed;
          z-index: 9999;
          display: none;
          align-items: center;
          justify-content: center;
          width: 18px; height: 18px;
          padding: 0;
          font: 700 14px -apple-system, system-ui, sans-serif;
          line-height: 1;
          color: #fff;
          background: \(accent.rgb);
          border: none;
          border-radius: 50%;
          cursor: pointer;
          user-select: none;
          -webkit-user-select: none;
          box-shadow: 0 1px 4px rgba(0,0,0,0.35);
        }
        #w42-add:hover { filter: brightness(1.1); }
        """
    }

    // MARK: - Artifact bridge (inline [[artifact:id]] embeds)

    /// CSS for the artifact inline-embed. The header mirrors the artifact
    /// gallery card / diagram card exactly — a macOS-styled bar with a
    /// document icon, the artifact's human title, and a ⤢ expand button —
    /// instead of a "LIVE" badge + raw id. Theme-driven via the `--w42-*`
    /// tokens (injected by CanvasTheme.css) so it tracks the app theme.
    /// `dark` is retained for signature stability; colors now come from tokens.
    private static func artifactBridgeCSS(dark: Bool) -> String {
        return """
        .w42-artifact-embed {
          margin: 1.2em 0;
          border: 1px solid var(--w42-elevated, rgba(120,120,128,0.28));
          border-radius: var(--w42-r-card, 10px);
          overflow: hidden;
          background: var(--w42-surface, #ffffff);
        }
        /* Card header — identical language to .w42-diagram-header. */
        .w42-artifact-header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 8px;
          height: 40px;
          padding: 0 8px 0 12px;
          box-sizing: border-box;
          background: var(--w42-elevated, rgba(120,120,128,0.07));
          border-bottom: 1px solid var(--w42-elevated, rgba(120,120,128,0.18));
          -webkit-backdrop-filter: saturate(180%) blur(8px);
          backdrop-filter: saturate(180%) blur(8px);
          user-select: none; -webkit-user-select: none;
        }
        .w42-artifact-header-main {
          display: inline-flex;
          align-items: center;
          gap: 7px;
          min-width: 0;
        }
        .w42-artifact-header-icon {
          flex: 0 0 auto;
          color: var(--w42-text-secondary, #6b6b70);
        }
        .w42-artifact-header-icon svg { width: 15px; height: 15px; display: block; }
        .w42-artifact-title {
          font-size: 12px;
          font-weight: 600;
          color: var(--w42-text-primary, #1a1a1a);
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }
        .w42-artifact-expand {
          all: unset;
          box-sizing: border-box;
          display: inline-flex;
          align-items: center;
          justify-content: center;
          width: 26px; height: 26px;
          flex: 0 0 auto;
          border-radius: 6px;
          cursor: pointer;
          color: var(--w42-text-secondary, #6b6b70);
          transition: background 0.1s ease, color 0.1s ease;
        }
        .w42-artifact-expand:hover {
          background: var(--w42-elevated, rgba(120,120,128,0.16));
          color: var(--w42-text-primary, #1a1a1a);
        }
        .w42-artifact-expand:active { background: var(--w42-elevated, rgba(120,120,128,0.28)); }
        .w42-artifact-expand svg { width: 14px; height: 14px; display: block; }
        .w42-artifact-frame {
          display: block;
          width: 100%;
          height: 200px;
          border: none;
          background: var(--w42-surface, #ffffff);
        }
        .w42-artifact-unavailable {
          margin: 0.6em 0;
          font-style: italic;
          color: var(--w42-red, rgb(239,68,68));
        }
        """
    }

    /// JavaScript bridge injected into the spec document when artifact embeds
    /// are present. Converts `.w42-artifact-ref` placeholder divs (emitted by
    /// `MarkdownArtifactRewriter`) into live iframes and wires the height-post
    /// postMessage listener so each iframe auto-sizes to its content — mirroring
    /// the `<w42-artifact>` custom element in CanvasTemplate but operating in
    /// the cross-origin context of a `file://` markdown document embedding
    /// `http://127.0.0.1` artifact iframes.
    private static let artifactBridgeScript = #"""
    (function () {
      "use strict";
      if (window.__w42ArtifactBridgeInstalled) { return; }
      window.__w42ArtifactBridgeInstalled = true;

      // Height bridge — resize each artifact iframe to its content height.
      // The ArtifactServer's composed shell posts:
      //   window.parent.postMessage({ type: "w42-artifact-height", height: h }, "*")
      // from a ResizeObserver + initial load handler. We receive it here and
      // match the source to the right iframe by comparing event.source to
      // each iframe's contentWindow.
      window.addEventListener("message", function (ev) {
        if (!ev.data || ev.data.type !== "w42-artifact-height") { return; }
        var h = parseInt(ev.data.height, 10);
        if (!(h > 0)) { return; }
        var frames = document.querySelectorAll("iframe.w42-artifact-frame");
        for (var i = 0; i < frames.length; i++) {
          if (frames[i].contentWindow === ev.source) {
            frames[i].style.height = h + "px";
            break;
          }
        }
      });

      // SF-Symbol-like glyphs matching the artifact gallery card header
      // (document + diagonal expand arrows). Same visual family as the
      // diagram card header so specs and artifacts read identically.
      var DOC_ICON = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M4 1.75h5L12.25 5v9.25H4z"/><path d="M9 1.75V5h3.25"/><line x1="5.75" y1="8" x2="10.25" y2="8"/><line x1="5.75" y1="10.5" x2="10.25" y2="10.5"/></svg>';
      var EXPAND_ICON = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M9.5 6.5 13 3"/><path d="M10 3h3v3"/><path d="M6.5 9.5 3 13"/><path d="M6 13H3v-3"/></svg>';

      // Post the expand intent to the native host on the always-registered
      // w42Diagram handler (see MarkdownWebView.Coordinator.didReceive). The
      // host opens the artifact full-surface — mirrors the gallery card's ⤢.
      function postExpand(id) {
        try {
          window.webkit.messageHandlers.w42Diagram.postMessage({ type: "artifact-expand", id: id });
        } catch (e) { /* handler absent (non-app WebView) — no-op */ }
      }

      // Convert each .w42-artifact-ref div into an iframe embed card whose
      // header matches the artifact gallery card (icon + title + ⤢ expand).
      function installArtifacts() {
        var refs = document.querySelectorAll("div.w42-artifact-ref");
        for (var i = 0; i < refs.length; i++) {
          (function (ref) {
            var id  = ref.getAttribute("data-w42-id")  || "";
            var src = ref.getAttribute("data-w42-src") || "";
            var title = ref.getAttribute("data-w42-title") || id;
            if (!id || !src) { return; }

            // Card wrapper
            var wrapper = document.createElement("div");
            wrapper.className = "w42-artifact-embed";

            // Header: document icon + title (left), expand button (right).
            var header = document.createElement("div");
            header.className = "w42-artifact-header";

            var main = document.createElement("div");
            main.className = "w42-artifact-header-main";
            var icon = document.createElement("span");
            icon.className = "w42-artifact-header-icon";
            icon.innerHTML = DOC_ICON;
            var titleEl = document.createElement("span");
            titleEl.className = "w42-artifact-title";
            titleEl.textContent = title;
            main.appendChild(icon);
            main.appendChild(titleEl);

            var expand = document.createElement("button");
            expand.type = "button";
            expand.className = "w42-artifact-expand";
            expand.title = "Open " + title + " full-surface";
            expand.setAttribute("aria-label", "Expand artifact");
            expand.innerHTML = EXPAND_ICON;
            expand.addEventListener("click", function (e) {
              e.preventDefault(); e.stopPropagation(); postExpand(id);
            });

            header.appendChild(main);
            header.appendChild(expand);
            wrapper.appendChild(header);

            // Iframe — src is the absolute ArtifactServer URL for this id.
            var frame = document.createElement("iframe");
            frame.className = "w42-artifact-frame";
            frame.setAttribute("scrolling", "no");
            frame.setAttribute("frameborder", "0");
            frame.src = src;
            wrapper.appendChild(frame);

            // Replace the placeholder div with the card.
            if (ref.parentNode) {
              ref.parentNode.replaceChild(wrapper, ref);
            }
          })(refs[i]);
        }
      }

      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", installArtifacts);
      } else {
        installArtifacts();
      }
    })();
    """#

}

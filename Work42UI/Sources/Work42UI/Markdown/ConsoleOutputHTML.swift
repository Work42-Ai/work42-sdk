// ConsoleOutputHTML.swift — a shared, terminal-styled HTML component for
// rendering command/console output blocks inside a markdown document
// (feat/testing-plan-and-qa-report-updates, aesthetics pass).
//
// Lives in Work42UI (not Work42App) so every markdown-HTML surface —
// QA report, Testing Plan, Spec — can render the SAME console look instead
// of each hand-rolling its own. First consumer: QAReportHTMLAugmenter's
// `console:<name>` fences.
//
// Deliberately NOT theme-adaptive like the rest of the --w42-* palette: a
// terminal window reads as a terminal window regardless of the surrounding
// document's light/dark mode, the same way Terminal.app doesn't retint to
// match whatever editor theme is next to it. Only the corner radius borrows
// the shared `--w42-r-card` token so it still sits comfortably inside a
// themed document.

import Foundation

public enum ConsoleOutputHTML {

    /// Emit once per document (e.g. via `MarkdownPreview.trailingHTML`) —
    /// NOT inline in the cmark-fed markdown text. cmark-gfm's `tagfilter`
    /// extension unconditionally escapes `<style>`/`<script>` tags fed
    /// through it regardless of blank-line padding (see
    /// `QAReportHTMLAugmenter`), so this must bypass cmark entirely.
    public static let css = """
    <style>
    .w42-console { display:block; margin:0.7em 0 1em; max-width:640px; border-radius:var(--w42-r-card, 10px);
      background:#1c1c1f; border:1px solid rgba(255,255,255,0.08);
      box-shadow:0 4px 14px rgba(0,0,0,0.22), inset 0 0 0 0.5px rgba(255,255,255,0.04); overflow:hidden; }
    .w42-console-bar { display:flex; align-items:center; gap:0.6em; padding:0.55em 0.85em;
      background:#232326; border-bottom:1px solid rgba(255,255,255,0.07); }
    .w42-console-dots { display:flex; gap:5px; flex:none; }
    .w42-console-dots span { width:9px; height:9px; border-radius:50%; display:block; }
    .w42-console-dots span:nth-child(1) { background:#ff5f56; }
    .w42-console-dots span:nth-child(2) { background:#ffbd2e; }
    .w42-console-dots span:nth-child(3) { background:#27c93f; }
    .w42-console-name { font-weight:700; font-family:ui-monospace,monospace; font-size:0.76em; color:#e7e7ea; margin-left:0.15em; }
    .w42-console-tag { font-family:ui-monospace,monospace; font-size:0.7em; color:#8c8c92; margin-left:auto; white-space:nowrap; }
    .w42-console pre { margin:0; padding:0.85em 1em; font-size:0.78em; line-height:1.6;
      color:#d8d8dc; font-family:ui-monospace,monospace; overflow-x:auto; white-space:pre-wrap; }
    </style>
    """

    /// A labeled terminal card: a header bar (traffic-light dots + `name` +
    /// right-aligned `tag`) over the pre-formatted `body` text. `name`/`tag`/
    /// `body` are raw (unescaped) strings — this function escapes them.
    public static func render(name: String, tag: String, body: String) -> String {
        """
        <div class="w42-console"><div class="w42-console-bar">\
        <span class="w42-console-dots"><span></span><span></span><span></span></span>\
        <span class="w42-console-name">\(esc(name))</span>\
        <span class="w42-console-tag">\(esc(tag))</span>\
        </div><pre>\(esc(body))</pre></div>
        """
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

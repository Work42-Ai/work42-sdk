// WebSectionScript.swift - Pure selector -> injected-JS generation.
//
// This is the deterministic, unit-testable seam for the selector
// isolation injected into the embedded webview (subtask T-005.2). It is
// intentionally free of WebKit/UIKit/SwiftUI so it can be exercised
// directly by tests (subtask .8 will assert on its output) without
// standing up a WKWebView.
//
// The generated script (run at `.atDocumentEnd`):
//   1. Finds the element matching the spec's CSS selector.
//   2. Walks the target's ancestor chain to <html>, hiding every
//      sibling of each ancestor so only the target's lineage remains.
//   3. Pins the target to fill the viewport, with a theme-adaptive
//      backdrop (CSS `color-scheme: light dark` + `Canvas`/`CanvasText`
//      system colors) so the crop follows the app's light/dark
//      appearance instead of a fixed white.
//   4. Re-applies the above via a debounced MutationObserver, because
//      SPA frameworks (e.g. Jira/React) re-render and restore the nodes
//      we hid.
//
// Why inject the selector as a JSON string literal: the selector is
// caller-supplied (it comes from a WebSectionSpec) and may contain
// quotes, backslashes, or other characters that would break or escape
// out of a naive JS string. JSON string syntax is a strict subset of
// JS string syntax, so a JSON-encoded selector is always a safe,
// correctly-escaped JS string literal.

import Foundation

/// Pure generator for the JavaScript injected into a `WebSectionView`'s
/// webview. No WebKit dependency so it is directly testable.
public enum WebSectionScript {

    /// Always-on Flutter-web accessibility enabler.
    ///
    /// Flutter web renders its semantics DOM (`flt-semantic-node-*` with
    /// `aria-label`) only while accessibility is enabled — clicking the
    /// `flt-semantics-placeholder` turns it on — and it RESETS on page load /
    /// hot-restart. Injected at `.atDocumentStart`, this polls for the
    /// placeholder and clicks it whenever it appears, so the semantic tree is
    /// ALWAYS present for the preview scan + highlight picker to read from ONE
    /// shared source of truth. Self-stopping on non-Flutter pages (after the
    /// initial load window, when no `flutter-view` is present) so it is safe to
    /// inject on every web tile.
    public static let flutterSemanticsEnabler: String = #"""
    (function() {
        if (window.__w42FlutterSemanticsEnabler) return;
        window.__w42FlutterSemanticsEnabler = true;
        var checks = 0;
        var iv = setInterval(function() {
            var p = document.querySelector('flt-semantics-placeholder');
            if (p) { try { p.click(); } catch (e) {} }
            checks++;
            if (checks > 20 && !document.querySelector(
                'flutter-view, flt-glass-pane, flt-semantics-host, flt-semantics-placeholder')) {
                clearInterval(iv);
            }
        }, 500);
    })();
    """#

    /// Build the selector-isolation script for a given CSS selector.
    ///
    /// The returned string is a self-contained IIFE suitable for a
    /// `WKUserScript` injected at `.atDocumentEnd`. The `selector` is
    /// embedded as a safely-escaped JS string literal, so any selector
    /// (including ones containing quotes or backslashes) is handled
    /// without breaking the script or allowing injection.
    ///
    /// The pinned target uses a theme-adaptive backdrop rather than a
    /// hardcoded white: `color-scheme: light dark` opts the crop into UA
    /// dark mode, and the `Canvas`/`CanvasText` system colors then resolve
    /// to the light or dark value based on the effective color scheme
    /// (which the webview inherits from the app's appearance via
    /// `prefers-color-scheme`). So in dark mode the backdrop is dark, in
    /// light mode it is white.
    ///
    /// - Parameter selector: A CSS selector identifying the single
    ///   element to isolate and pin to fill the viewport.
    /// - Returns: JavaScript source for a `WKUserScript`.
    public static func isolation(selector: String) -> String {
        let literal = jsStringLiteral(selector)
        return """
        (function() {
          var SELECTOR = \(literal);
          function isolate() {
            if (!SELECTOR || !SELECTOR.trim()) return;
            var target = document.querySelector(SELECTOR);
            if (!target) return;
            var ancestors = new Set();
            var el = target;
            while (el && el !== document.documentElement) { ancestors.add(el); el = el.parentElement; }
            ancestors.forEach(function(a) {
              var parent = a.parentElement;
              if (!parent) return;
              Array.prototype.slice.call(parent.children).forEach(function(c) {
                if (c !== a) c.style.setProperty('display', 'none', 'important');
              });
            });
            target.style.cssText = 'position:fixed!important;top:0;left:0;width:100vw;height:100vh;overflow:auto;z-index:99999;color-scheme:light dark;background:Canvas;color:CanvasText;padding:20px;box-sizing:border-box;';
          }
          isolate();
          var t;
          var obs = new MutationObserver(function() { clearTimeout(t); t = setTimeout(isolate, 100); });
          if (document.body) {
            obs.observe(document.body, { childList: true, subtree: true });
          }
        })();
        """
    }

    /// Build the JS->Swift signal script for a given selector + message
    /// handler name (subtask T-005.4).
    ///
    /// The returned IIFE posts a small JSON payload to
    /// `window.webkit.messageHandlers.<handlerName>.postMessage(...)`
    /// whenever the target section appears (initial load) and whenever
    /// the document title changes, so a consumer (e.g. the Jira widget) can
    /// react to "issue loaded" / title updates. It is defensive: if the
    /// message handler is not registered (nil-callback case — the seam is
    /// optional) the `window.webkit.messageHandlers.<handlerName>` lookup
    /// is guarded so the script never throws.
    ///
    /// Payload shape (kept tiny and stable so the Swift side can decode it
    /// without a schema): `{ type: "loaded" | "title", title: <string> }`.
    ///
    /// Like `isolation(selector:)` this is intentionally WebKit-free so it
    /// can be unit-tested (subtask .8) without standing up a WKWebView.
    /// Both the selector and the handler name are embedded as
    /// safely-escaped JS string literals.
    ///
    /// - Parameters:
    ///   - selector: CSS selector for the target section; a `loaded`
    ///     signal is posted once it is present in the DOM.
    ///   - handlerName: the `WKScriptMessageHandler` name registered on
    ///     the `WKUserContentController` Swift-side.
    /// - Returns: JavaScript source for a `WKUserScript`.
    public static func signal(selector: String, handlerName: String) -> String {
        let selectorLiteral = jsStringLiteral(selector)
        let handlerLiteral = jsStringLiteral(handlerName)
        return """
        (function() {
          var SELECTOR = \(selectorLiteral);
          var HANDLER = \(handlerLiteral);
          function post(payload) {
            try {
              var mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[HANDLER];
              if (mh && typeof mh.postMessage === 'function') { mh.postMessage(payload); }
            } catch (e) { /* no handler registered: optional seam, ignore */ }
          }
          var loadedPosted = false;
          function checkLoaded() {
            if (loadedPosted) return;
            if (!SELECTOR || !SELECTOR.trim()) return;
            if (document.querySelector(SELECTOR)) {
              loadedPosted = true;
              post({ type: 'loaded', title: document.title });
            }
          }
          var lastTitle = document.title;
          function checkTitle() {
            if (document.title !== lastTitle) {
              lastTitle = document.title;
              post({ type: 'title', title: document.title });
            }
          }
          checkLoaded();
          var t;
          var obs = new MutationObserver(function() {
            clearTimeout(t);
            t = setTimeout(function() { checkLoaded(); checkTitle(); }, 100);
          });
          if (document.documentElement) {
            obs.observe(document.documentElement, { childList: true, subtree: true });
          }
        })();
        """
    }

    /// Build the text-selection tracking script for the PR WebView widget
    /// (AC2 — cozy-nimbus).
    ///
    /// The returned IIFE listens for `selectionchange` events and posts a
    /// `{ type: "textSelection", text, x, y, width, height, devicePixelRatio,
    /// scrollX, scrollY, filePath }` message (coordinates in CSS-pixel page
    /// space) to `window.webkit.messageHandlers.<handlerName>` whenever the
    /// selection is non-empty. An empty / cleared selection posts
    /// `{ type: "clear" }` instead. The handler guard (`mh &&
    /// typeof mh.postMessage === 'function'`) makes this script safe even
    /// when no handler is registered — same pattern as `signal`.
    ///
    /// AC7 (cozy-nimbus): the DOM no longer scrapes the diff line / side. That
    /// walk (`tr.diff-line-row` / `data-line-number` / `diff-line-number-*` /
    /// `data-line-anchor`) silently failed across GitHub's React-diff DOM
    /// versions. We now post ONLY the stable bits — the selected `text` and a
    /// `filePath` hint (`data-path`) — and Swift recovers the precise
    /// `(line, side)` by matching the text against the PR's real unified diff
    /// (`UnifiedDiffLocator`). The rect is for the `+` bubble overlay.
    ///
    /// Coordinate note: `getBoundingClientRect()` returns viewport-relative
    /// coordinates; adding `window.scrollX`/`scrollY` converts them to
    /// page-space coordinates so the Swift side can offset back by the
    /// current scroll position to get a stable view-space rect on each call.
    ///
    /// Scroll suppression (AC22 — janks-and-random-crashes.18):
    /// GitHub PR pages (React renderer, diff scroll containers) can trigger
    /// `selectionchange` on every scroll frame when a selection is active. Each
    /// event would `postMessage` a new rect → `PRCommentSelectionLayer.selectionRect`
    /// `@State` write → SwiftUI overlay body re-evaluation → `GeometryReader`
    /// rebuild per frame. A capture-phase `scroll` listener gates the
    /// `selectionchange` posts while scrolling and re-derives the rect from
    /// the live DOM once after the scroll settles (150 ms), so the `+` bubble
    /// snaps to the correct viewport position without a per-frame re-render.
    /// The `clear` path is also gated so an in-flight scroll cannot dismiss a
    /// CommentComposerPopover the user opened before scrolling.
    ///
    /// - Parameter handlerName: The `WKScriptMessageHandler` name registered
    ///   on the `WKUserContentController` Swift-side.
    /// - Returns: JavaScript source for a `WKUserScript`.
    public static func selectionTracking(handlerName: String) -> String {
        let handlerLiteral = jsStringLiteral(handlerName)
        return """
        (function() {
          var HANDLER = \(handlerLiteral);
          function post(payload) {
            try {
              var mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[HANDLER];
              if (mh && typeof mh.postMessage === 'function') { mh.postMessage(payload); }
            } catch (e) { /* no handler registered: optional seam, ignore */ }
          }

          // --- Scroll gate (AC22) ---
          // GitHub PR pages can fire selectionchange on every scroll frame
          // (React renderer / nested overflow scroll containers). Gate all
          // postMessage calls while a scroll is in flight; after the scroll
          // settles re-derive the current selection rect and post once, so
          // the Swift @State is written at most once per scroll rather than
          // per frame. The clear path is likewise gated so a scroll cannot
          // inadvertently dismiss an open CommentComposerPopover.
          var isScrolling = false;
          var scrollTimer;

          // Walk the DOM upward from a range collecting the nearest ancestors'
          // `data-*` attributes into a GENERIC context map (data- prefix
          // stripped, nearest-ancestor-wins). This is deliberately site-neutral:
          // GitHub's `data-path` arrives as ctx.path, but any HTML widget's
          // annotations come through the same channel. A widget's
          // WebSelectionResolver interprets whichever keys it cares about;
          // the SDK itself scrapes nothing site-specific. Bounded hop count
          // keeps this cheap on deep DOMs.
          function extractDomContext(range) {
            var ctx = {};
            var node = range.startContainer;
            var hops = 0;
            while (node && node !== document.body && hops < 12) {
              if (node.nodeType === 1 && node.attributes) {
                for (var i = 0; i < node.attributes.length; i++) {
                  var attr = node.attributes[i];
                  if (attr.name && attr.name.indexOf('data-') === 0) {
                    var key = attr.name.slice(5);
                    // Nearest ancestor wins: don't overwrite a closer node's value.
                    if (!(key in ctx)) { ctx[key] = attr.value; }
                  }
                }
              }
              node = node.parentNode;
              hops++;
            }
            return ctx;
          }

          // Re-derive and post the current selection after scroll settles.
          // Uses the live DOM so the reported rect reflects the post-scroll
          // viewport position (getBoundingClientRect is scroll-position-aware).
          function postCurrentSelection() {
            var sel = window.getSelection();
            if (!sel) return;
            var text = sel.toString();
            if (!text || text.trim().length === 0) return;
            try {
              var range = sel.getRangeAt(0);
              var rect = range.getBoundingClientRect();
              post({
                type: 'textSelection',
                text: text,
                x: rect.left + (window.scrollX || 0),
                y: rect.top + (window.scrollY || 0),
                width: rect.width,
                height: rect.height,
                devicePixelRatio: window.devicePixelRatio || 1,
                scrollX: window.scrollX || 0,
                scrollY: window.scrollY || 0,
                domContext: extractDomContext(range)
              });
            } catch (e) { /* ignore — no active range after scroll */ }
          }

          // Capture-phase scroll listener on window catches scroll events from
          // the page root AND from nested overflow containers in GitHub diffs.
          window.addEventListener('scroll', function() {
            isScrolling = true;
            clearTimeout(scrollTimer);
            scrollTimer = setTimeout(function() {
              isScrolling = false;
              // One authoritative post after scroll settles so the bubble
              // snaps to the correct position. No-op when selection is empty.
              postCurrentSelection();
            }, 150);
          }, true /* capture */);

          document.addEventListener('selectionchange', function() {
            var sel = window.getSelection();
            var text = sel ? sel.toString() : '';
            if (!text || text.trim().length === 0) {
              // Gate the clear during scroll: do not dismiss an open popover
              // because a scroll happened to briefly invalidate the selection.
              if (!isScrolling) {
                post({ type: 'clear' });
              }
              return;
            }
            // Gate: skip posting during scroll to avoid per-frame @State writes
            // that rebuild the GeometryReader overlay in PRCommentSelectionLayer.
            if (isScrolling) return;
            try {
              var range = sel.getRangeAt(0);
              var rect = range.getBoundingClientRect();
              // Attach a generic map of nearby ancestor `data-*` attributes
              // (see extractDomContext). A widget's WebSelectionResolver turns
              // these into a useful anchor (GitHub: ctx.path + line matching
              // against the PR's unified diff); the SDK scrapes nothing
              // site-specific here.
              post({
                type: 'textSelection',
                text: text,
                x: rect.left + (window.scrollX || 0),
                y: rect.top + (window.scrollY || 0),
                width: rect.width,
                height: rect.height,
                devicePixelRatio: window.devicePixelRatio || 1,
                scrollX: window.scrollX || 0,
                scrollY: window.scrollY || 0,
                domContext: extractDomContext(range)
              });
            } catch (e) { post({ type: 'clear' }); }
          });
        })();
        """
    }

    /// Build the element-picker script for the WKWebView picker bridge
    /// (lanky-pine.2).
    ///
    /// The returned IIFE:
    ///   1. Reads `window.__pickerCore` (set by the separately-injected
    ///      `picker-core.js` asset script at `.atDocumentStart`).
    ///   2. Wires `createPickerCore({ emit, capture }, { accentColor })` callbacks to post JSON
    ///      payloads to `window.webkit.messageHandlers.<handlerName>`.
    ///   3. Exposes `window.__w42Picker = { start, stop }` so Swift can arm /
    ///      disarm by evaluating JS.
    ///   4. Registers a capture-phase Esc keydown listener that calls `stop()`.
    ///
    /// Payload shapes posted to the handler:
    ///   - capture: `{ type: "capture", selector, text, url, x, y, width,
    ///                 height, scrollX, scrollY, devicePixelRatio }`
    ///   - stop:    `{ type: "stop" }`
    ///
    /// Like the other script generators this is intentionally WebKit-free and
    /// pure-string so it can be unit-tested without standing up a WKWebView.
    /// The handler name and accent hex are embedded as safely-escaped JS string
    /// literals.
    ///
    /// - Parameters:
    ///   - handlerName: The `WKScriptMessageHandler` name registered
    ///     on the `WKUserContentController` Swift-side.
    ///   - accentHex: A CSS hex color string (e.g. `"#3b82f6"`) used for
    ///     overlay borders, fills, and badge backgrounds. Defaults to
    ///     Tailwind blue-500 for backward compatibility.
    /// - Returns: JavaScript source for a `WKUserScript`.
    public static func elementPicker(handlerName: String, accentHex: String = "#3b82f6") -> String {
        let handlerLiteral = jsStringLiteral(handlerName)
        let accentLiteral = jsStringLiteral(accentHex)
        return """
        (function() {
          var HANDLER = \(handlerLiteral);
          var ACCENT = \(accentLiteral);
          function post(payload) {
            try {
              var mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[HANDLER];
              if (mh && typeof mh.postMessage === 'function') { mh.postMessage(payload); }
            } catch(e) {}
          }
          var pickerCore = null;
          if (window.__pickerCore && typeof window.__pickerCore.createPickerCore === 'function') {
            pickerCore = window.__pickerCore.createPickerCore({
              emit: function(state) {
                // state changes (hover) are internal; no payload posted for emit
              },
              capture: function(info) {
                var bounds = info.bounds || {};
                var sx = window.scrollX || 0;
                var sy = window.scrollY || 0;
                post({
                  type: 'capture',
                  selector: info.selector || '',
                  text: info.text || '',
                  url: info.url || window.location.href,
                  x: (bounds.x || 0) + sx,
                  y: (bounds.y || 0) + sy,
                  width: bounds.width || 0,
                  height: bounds.height || 0,
                  scrollX: sx,
                  scrollY: sy,
                  devicePixelRatio: window.devicePixelRatio || 1
                });
              },
              deselect: function(selector) {
                post({ type: 'deselect', selector: selector });
              }
            }, { accentColor: ACCENT });
          }
          function doStop() {
            if (pickerCore && typeof pickerCore.stop === 'function') {
              pickerCore.stop();
            }
            post({ type: 'stop' });
          }
          document.addEventListener('keydown', function(event) {
            if (event.key === 'Escape') {
              doStop();
            }
          }, true);
          window.__w42Picker = {
            start: function() {
              if (pickerCore && typeof pickerCore.start === 'function') {
                pickerCore.start();
              }
            },
            stop: function() {
              doStop();
            }
          };
        })();
        """
    }

    // MARK: - Find-in-page script builders (dewy-flint.1)

    /// Build the find-in-page script for a given query.
    ///
    /// The returned IIFE:
    ///   1. Clears any existing `w42-find` marks from a previous search (so
    ///      re-running find on a new query starts fresh).
    ///   2. Walks the page's text nodes (skipping script/style/noscript/
    ///      textarea subtrees) and wraps every case-insensitive occurrence of
    ///      the query in a `<mark class="w42-find">`, preserving the original
    ///      casing of the matched text in the visible output.
    ///   3. Marks the first match additionally with class `w42-find-active`
    ///      using `activeColor`; all other matches are yellow (`#ffeb3b`).
    ///   4. Scrolls the active match into view.
    ///   5. Persists `{ marks, activeIndex }` on `window.__w42FindState` so
    ///      `findNext()` / `findPrevious()` can advance without re-scanning.
    ///   6. Returns `{ current, total }`: `current` is the 1-based index of
    ///      the active match (0 when there are no matches), `total` is the
    ///      total match count.
    ///
    /// Cross-origin iframes are NOT searched — the TreeWalker is rooted at
    /// `document.body` of the top frame only (accepted limitation, per spec).
    ///
    /// Like the other script generators this is intentionally WebKit-free so
    /// it can be unit-tested without a WKWebView. The query and activeColor are
    /// embedded as safely-escaped JS string literals via `jsStringLiteral`.
    ///
    /// - Parameters:
    ///   - query: The search string. An empty or blank query clears existing
    ///     highlights and returns `{ current: 0, total: 0 }`.
    ///   - activeColor: A CSS color string (e.g. `"#007aff"`) applied as the
    ///     background of the active match mark. Caller is responsible for
    ///     resolving the user's system accent color at call time.
    /// - Returns: JavaScript source for a self-contained IIFE.
    public static func find(query: String, activeColor: String) -> String {
        let literal = jsStringLiteral(query)
        let activeColorLiteral = jsStringLiteral(activeColor)
        return """
        (function() {
          var QUERY = \(literal);
          var ACTIVE_COLOR = \(activeColorLiteral);
          // Clear existing w42-find marks and reset page state.
          var existing = Array.prototype.slice.call(document.querySelectorAll('mark.w42-find'));
          existing.forEach(function(mark) {
            var parent = mark.parentNode;
            if (!parent) return;
            parent.replaceChild(document.createTextNode(mark.textContent), mark);
            parent.normalize();
          });
          window.__w42FindState = null;
          if (!QUERY || !QUERY.trim()) { return { current: 0, total: 0 }; }
          // Tags whose subtrees are skipped (script text, CSS, etc.).
          var EXCLUDED = { script: 1, style: 1, noscript: 1, textarea: 1 };
          function isExcluded(node) {
            var el = node.parentElement;
            while (el && el !== document.body && el !== document.documentElement) {
              if (EXCLUDED[el.tagName.toLowerCase()]) return true;
              el = el.parentElement;
            }
            return false;
          }
          // Collect all eligible text nodes in document order.
          var walker = document.createTreeWalker(
            document.body || document.documentElement,
            NodeFilter.SHOW_TEXT,
            null
          );
          var textNodes = [];
          while (walker.nextNode()) {
            var n = walker.currentNode;
            if (n.nodeValue && n.nodeValue.trim() && !isExcluded(n)) textNodes.push(n);
          }
          var lq = QUERY.toLowerCase();
          var marks = [];
          textNodes.forEach(function(textNode) {
            var text = textNode.nodeValue;
            var lt = text.toLowerCase();
            if (lt.indexOf(lq) === -1) return;
            var parent = textNode.parentNode;
            if (!parent) return;
            var frag = document.createDocumentFragment();
            var last = 0, idx;
            while ((idx = lt.indexOf(lq, last)) !== -1) {
              if (idx > last) frag.appendChild(document.createTextNode(text.slice(last, idx)));
              var mark = document.createElement('mark');
              mark.className = 'w42-find';
              mark.style.cssText = 'background:#ffeb3b;color:inherit;padding:0;border-radius:2px;';
              mark.textContent = text.slice(idx, idx + lq.length);
              frag.appendChild(mark);
              marks.push(mark);
              last = idx + lq.length;
            }
            if (last < text.length) frag.appendChild(document.createTextNode(text.slice(last)));
            parent.replaceChild(frag, textNode);
          });
          var total = marks.length;
          if (total > 0) {
            marks[0].className = 'w42-find w42-find-active';
            marks[0].style.cssText = 'background:' + ACTIVE_COLOR + ';color:inherit;padding:0;border-radius:2px;';
            \(scrollActiveIntoViewSnippet("marks[0]"));
          }
          window.__w42FindState = { marks: marks, activeIndex: 0 };
          return { current: total > 0 ? 1 : 0, total: total };
        })();
        """
    }

    /// Build the find-next script: advance the active match by one, wrapping
    /// from the last match back to the first.
    ///
    /// Uses `window.__w42FindState` set by `find(query:activeColor:)` — returns
    /// `{ current: 0, total: 0 }` immediately when there is no active search
    /// state or no matches.
    ///
    /// - Parameter activeColor: A CSS color string (e.g. `"#007aff"`) applied as
    ///   the background of the newly active match mark. Should match the value
    ///   passed to the originating `find(query:activeColor:)` call.
    /// - Returns: JavaScript source for a self-contained IIFE.
    public static func findNext(activeColor: String) -> String {
        let activeColorLiteral = jsStringLiteral(activeColor)
        return """
        (function() {
          var ACTIVE_COLOR = \(activeColorLiteral);
          var state = window.__w42FindState;
          if (!state || !state.marks || state.marks.length === 0) { return { current: 0, total: 0 }; }
          var marks = state.marks;
          var total = marks.length;
          marks[state.activeIndex].className = 'w42-find';
          marks[state.activeIndex].style.cssText = 'background:#ffeb3b;color:inherit;padding:0;border-radius:2px;';
          state.activeIndex = (state.activeIndex + 1) % total;
          marks[state.activeIndex].className = 'w42-find w42-find-active';
          marks[state.activeIndex].style.cssText = 'background:' + ACTIVE_COLOR + ';color:inherit;padding:0;border-radius:2px;';
          \(scrollActiveIntoViewSnippet("marks[state.activeIndex]"));
          return { current: state.activeIndex + 1, total: total };
        })();
        """
    }

    /// Build the find-previous script: move the active match back by one,
    /// wrapping from the first match to the last.
    ///
    /// Uses `window.__w42FindState` set by `find(query:activeColor:)` — returns
    /// `{ current: 0, total: 0 }` immediately when there is no active search
    /// state or no matches.
    ///
    /// - Parameter activeColor: A CSS color string (e.g. `"#007aff"`) applied as
    ///   the background of the newly active match mark. Should match the value
    ///   passed to the originating `find(query:activeColor:)` call.
    /// - Returns: JavaScript source for a self-contained IIFE.
    public static func findPrevious(activeColor: String) -> String {
        let activeColorLiteral = jsStringLiteral(activeColor)
        return """
        (function() {
          var ACTIVE_COLOR = \(activeColorLiteral);
          var state = window.__w42FindState;
          if (!state || !state.marks || state.marks.length === 0) { return { current: 0, total: 0 }; }
          var marks = state.marks;
          var total = marks.length;
          marks[state.activeIndex].className = 'w42-find';
          marks[state.activeIndex].style.cssText = 'background:#ffeb3b;color:inherit;padding:0;border-radius:2px;';
          state.activeIndex = (state.activeIndex - 1 + total) % total;
          marks[state.activeIndex].className = 'w42-find w42-find-active';
          marks[state.activeIndex].style.cssText = 'background:' + ACTIVE_COLOR + ';color:inherit;padding:0;border-radius:2px;';
          \(scrollActiveIntoViewSnippet("marks[state.activeIndex]"));
          return { current: state.activeIndex + 1, total: total };
        })();
        """
    }

    /// Build the find-clear script: unwrap every `w42-find` mark, restoring
    /// the original text nodes, and reset `window.__w42FindState` to `null`.
    ///
    /// Safe to call when no find is active — the `querySelectorAll` returns
    /// an empty list and the state assignment is a no-op.
    ///
    /// - Returns: JavaScript source for a self-contained IIFE.
    public static func findClear() -> String {
        return """
        (function() {
          var existing = Array.prototype.slice.call(document.querySelectorAll('mark.w42-find'));
          existing.forEach(function(mark) {
            var parent = mark.parentNode;
            if (!parent) return;
            parent.replaceChild(document.createTextNode(mark.textContent), mark);
            parent.normalize();
          });
          window.__w42FindState = null;
        })();
        """
    }

    /// A JS statement that reliably scrolls the given element expression into
    /// view inside an embedded WKWebView.
    ///
    /// The browser find bar's original inline `scrollIntoView({behavior:'smooth'})`
    /// fired synchronously right after the `<mark>` was spliced into the DOM —
    /// before layout settled — and `'smooth'` scrolls are frequently dropped or
    /// interrupted in WKWebView, so the active match often did not move into
    /// view. This defers the scroll across two animation frames (so layout is
    /// committed) and uses an instant (`'auto'`) scroll, which lands reliably.
    ///
    /// - Parameter elementExpr: a JS expression evaluating to the target
    ///   `Element` (e.g. `"marks[0]"`). Not string-escaped — it is code.
    static func scrollActiveIntoViewSnippet(_ elementExpr: String) -> String {
        """
        (function(__el){
          if (!__el) return;
          requestAnimationFrame(function(){
            try {
              // Explicitly centre the element in its scroll container. We compute
              // the delta rather than rely on scrollIntoView({block:'center'}),
              // which is unreliable in WKWebView (dropped when the page sets CSS
              // scroll-behavior: smooth, and asymmetric up/down on some layouts).
              function scrollableAncestor(node){
                var n = node.parentElement;
                while (n){
                  var s = getComputedStyle(n), oy = s.overflowY;
                  if ((oy === 'auto' || oy === 'scroll' || oy === 'overlay') &&
                      n.scrollHeight > n.clientHeight + 1) return n;
                  n = n.parentElement;
                }
                return null;
              }
              var er = __el.getBoundingClientRect();
              var sc = scrollableAncestor(__el);
              if (sc){
                var cr = sc.getBoundingClientRect();
                sc.scrollTop += (er.top - cr.top) - (sc.clientHeight / 2) + (er.height / 2);
              } else {
                var doc = document.scrollingElement || document.documentElement;
                var y = (window.scrollY || doc.scrollTop || 0) + er.top - (window.innerHeight / 2) + (er.height / 2);
                window.scrollTo(0, y < 0 ? 0 : y);
              }
            } catch (e) {}
          });
        })(\(elementExpr))
        """
    }

    /// Catches clicks on links that another widget owns, inside the page.
    ///
    /// Single-page apps (Linear, Jira) change page with `history.pushState`, which never reaches the web
    /// view's navigation delegate, so the host's link router cannot see an ordinary click. This script
    /// listens for `click` in the CAPTURE phase, before the app's own handler. When the clicked anchor's
    /// absolute `href` matches one of `window.__w42Links.patterns` (a list of `{source, flags}` pushed by
    /// the native side via `WebSectionLiveView.setLinkPatterns`), it cancels the click and posts
    /// `{url}` to `handlerName`; the host then focuses the owning widget.
    ///
    /// Inert until patterns are set or `all` is turned on (`WebSectionLiveView.setInterceptAllLinks`, which makes every
    /// web link the host's to route). A click the host declines is replayed (`window.__w42Links.replay()`). Clicks with ⌘ ⌃ ⇧ or ⌥ held, non-primary buttons, and clicks the
    /// page already handled are left alone, so ⌥-click navigates in place. A pattern the page can't
    /// compile is skipped.
    public static func linkInterceptor(handlerName: String) -> String {
        let handlerLiteral = jsStringLiteral(handlerName)
        return """
        (function() {
          if (window.__w42Links) { return; }
          var HANDLER = \(handlerLiteral);
          var state = window.__w42Links = { patterns: [], all: false, pending: null, replaying: false };
          function matches(href) {
            for (var i = 0; i < state.patterns.length; i++) {
              var p = state.patterns[i];
              try { if (new RegExp(p.source, p.flags).test(href)) { return true; } } catch (e) { /* bad pattern: skip */ }
            }
            return false;
          }
          // `all` mode: every web link is the host's to route. mailto:, javascript: and the like, and
          // fragment links inside the current document, stay with the page.
          function isWebLink(a) {
            var proto = a.protocol;
            if (proto !== 'http:' && proto !== 'https:' && proto !== 'work42:') { return false; }
            if (a.hash && a.href.split('#')[0] === location.href.split('#')[0]) { return false; }
            return true;
          }
          // The host declined the link: send the same click through again so the page (a single-page
          // app routing with pushState, or a plain navigation) handles it exactly as it would have.
          state.replay = function() {
            var a = state.pending; state.pending = null;
            if (!a || !a.isConnected) { return false; }
            state.replaying = true;
            try { a.click(); } finally { state.replaying = false; }
            return true;
          };
          document.addEventListener('click', function(e) {
            if (state.replaying) { return; }
            if ((!state.all && state.patterns.length === 0) || e.defaultPrevented) { return; }
            if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) { return; }
            var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
            if (!a || typeof a.href !== 'string') { return; }
            var href = a.href;
            if (state.all ? !isWebLink(a) : !matches(href)) { return; }
            e.preventDefault();
            e.stopImmediatePropagation();
            state.pending = a;
            try {
              var mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[HANDLER];
              if (mh && typeof mh.postMessage === 'function') { mh.postMessage({ url: href }); }
            } catch (err) { /* no handler: nothing to hand the link to */ }
          }, true);
        })();
        """
    }

    /// Encode an arbitrary string as a JavaScript string literal
    /// (including the surrounding double quotes), safely escaping every
    /// character that would otherwise break out of, or alter, the
    /// literal. Uses JSON encoding, whose string grammar is a subset of
    /// JavaScript's, so the result is always a valid JS string literal.
    static func jsStringLiteral(_ value: String) -> String {
        // JSONSerialization escapes quotes, backslashes, and control
        // characters. We wrap the string in an array to satisfy the
        // top-level-container requirement, then strip the brackets.
        if let data = try? JSONSerialization.data(withJSONObject: [value]),
           let json = String(data: data, encoding: .utf8),
           json.hasPrefix("["), json.hasSuffix("]") {
            let inner = json.dropFirst().dropLast()
            let trimmed = inner.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        // Defensive manual fallback (should be unreachable for String
        // inputs). Escape the minimal set needed for a valid JS literal.
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }
}

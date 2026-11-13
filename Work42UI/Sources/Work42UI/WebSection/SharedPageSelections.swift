// SharedPageSelections.swift — everyone's text selection in a shared web page, in their colour (WOR-773 §6).
//
// A shared widget that renders web (Artifacts, a plugin's page) is one page for everyone, each at their own size and scroll, so a
// selection cannot travel as coordinates. It travels as what was selected: the quote, with a little text before and after it, which
// finds the same words again in anyone's copy of the page (the way web annotations are anchored). This is the page side of it: a
// script that reports this person's selection as such a quote, and draws everyone else's as a highlight in their colour with a name
// tag. It draws with the CSS Custom Highlight API, so the page's own DOM is never changed; the tags sit in a shadow root outside the
// page's text, so they are never part of anyone's selection or of the text a quote is found in. The host decides who sees what: this
// only reports and draws.

import Foundation
import WebKit

/// Selected words in a page, found again by the text around them.
public struct PageQuote: Codable, Equatable, Sendable {
    public var quote: String
    public var prefix: String
    public var suffix: String

    public init(quote: String, prefix: String, suffix: String) {
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
    }
}

/// A person's selection in a page: one quote, or for a long one its first and last words (`end`), the highlight running between.
public struct PageSelectionReport: Codable, Equatable, Sendable {
    public var start: PageQuote
    public var end: PageQuote?

    public init(start: PageQuote, end: PageQuote? = nil) {
        self.start = start
        self.end = end
    }
}

/// Someone else's selection to draw: their name for the tag, their colour (any CSS colour) and the highlight's fill.
public struct SharedPageSelection: Codable, Equatable, Sendable {
    public var name: String
    public var color: String
    public var fill: String
    public var start: PageQuote
    public var end: PageQuote?

    public init(name: String, color: String, fill: String, start: PageQuote, end: PageQuote? = nil) {
        self.name = name
        self.color = color
        self.fill = fill
        self.start = start
        self.end = end
    }
}

/// Reports this person's selection in `webView` and draws everyone else's. Attach once per page; `detach` takes it away.
@MainActor
public final class SharedPageSelections {
    public static let handlerName = "w42SharedSelection"

    private weak var webView: WKWebView?
    private let onLocalChange: (PageSelectionReport?) -> Void
    private var proxy: Proxy?
    private var shown: [SharedPageSelection] = []

    /// `onLocalChange` hears this person's selection each time it settles, and nil when it is cleared.
    public init(webView: WKWebView, onLocalChange: @escaping (PageSelectionReport?) -> Void) {
        self.webView = webView
        self.onLocalChange = onLocalChange
        let controller = webView.configuration.userContentController
        let proxy = Proxy()
        proxy.owner = self
        self.proxy = proxy
        // A page attached twice (a cached view shown again) has one handler, never two.
        controller.removeScriptMessageHandler(forName: Self.handlerName)
        controller.add(proxy, name: Self.handlerName)
        // For the pages it loads from now on (once per controller: a user script cannot be taken out alone), and for the one it
        // shows now. The script itself runs once per page.
        if !Self.installed.contains(controller) {
            Self.installed.add(controller)
            controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        webView.evaluateJavaScript(Self.script, completionHandler: nil)
    }

    /// The content controllers that already carry the script.
    private static let installed = NSHashTable<WKUserContentController>.weakObjects()

    /// Draws `selections` (everyone else's), replacing what was drawn. Kept, so a page that reloads draws them again.
    public func show(_ selections: [SharedPageSelection]) {
        guard selections != shown else { return }
        shown = selections
        draw()
    }

    /// What this person has selected in the page now, read from the page itself: `.nothing` when no text is selected, `.unknown`
    /// when the page could not be asked (it is loading). The host reads it on its own beat, so the others mirror the selection as it
    /// is, whatever events were missed.
    public func currentSelection() async -> CurrentSelection {
        guard let webView,
              let value = try? await webView.evaluateJavaScript("window.__w42Shared ? window.__w42Shared.snapshot() : undefined"),
              let text = value as? String
        else { return .unknown }
        guard text != "null", let data = text.data(using: .utf8),
              let report = try? JSONDecoder().decode(PageSelectionReport.self, from: data)
        else { return .nothing }
        return .selected(report)
    }

    public enum CurrentSelection: Equatable, Sendable {
        case unknown
        case nothing
        case selected(PageSelectionReport)
    }

    /// Stops reporting and drawing: what this drew goes, and the page script falls silent.
    public func detach() {
        shown = []
        webView?.evaluateJavaScript("window.__w42Shared && window.__w42Shared.show([])", completionHandler: nil)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        proxy?.owner = nil
        proxy = nil
    }

    private func draw() {
        guard let json = try? JSONEncoder().encode(shown), let text = String(data: json, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__w42Shared && window.__w42Shared.show(\(text))", completionHandler: nil)
    }

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            // A page that loaded again draws what it had.
            draw()
        case "select":
            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  let report = try? JSONDecoder().decode(PageSelectionReport.self, from: data)
            else { return }
            onLocalChange(report)
        case "clear":
            onLocalChange(nil)
        default:
            break
        }
    }

    /// The content controller retains its handlers: this holds the owner weakly so the page never keeps it alive.
    private final class Proxy: NSObject, WKScriptMessageHandler {
        weak var owner: SharedPageSelections?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body
            MainActor.assumeIsolated { owner?.received(body) }
        }
    }

    // MARK: The page script

    /// Reports the selection (debounced) as `{type: "select", start, end?}` or `{type: "clear"}`, and exposes
    /// `__w42Shared.show(selections)`. Whitespace is collapsed in every quote, so a page laid out at another width still matches.
    static let script = #"""
    (function () {
      if (window.__w42Shared) { return; }
      var HANDLER = 'w42SharedSelection', CONTEXT = 32, MAX_QUOTE = 200, HALF = 96;
      function post(message) {
        try { window.webkit.messageHandlers[HANDLER].postMessage(message); } catch (e) {}
      }
      function norm(text) { return String(text || '').replace(/\s+/g, ' '); }
      var host = null, root = null, styleSheet = null, current = [];

      function isOurs(node) {
        var element = node && (node.nodeType === 1 ? node : node.parentElement);
        return !!(element && element.closest && element.closest('[data-w42-shared]'));
      }

      // This person's selection, as a quote with the words around it.
      function textBefore(range) {
        var r = document.createRange();
        r.setStart(document.body, 0);
        r.setEnd(range.startContainer, range.startOffset);
        return norm(r.toString()).slice(-CONTEXT).trimStart();
      }
      function textAfter(range) {
        var r = document.createRange();
        r.setStart(range.endContainer, range.endOffset);
        r.setEnd(document.body, document.body.childNodes.length);
        return norm(r.toString()).slice(0, CONTEXT).trimEnd();
      }
      var timer = null, last = '';
      // The selection now, as the report the host is sent; null when nothing is selected.
      function snapshot() {
        var selection = window.getSelection();
        var empty = !selection || selection.rangeCount === 0 || selection.isCollapsed;
        var range = empty ? null : selection.getRangeAt(0);
        var text = range && document.body && !isOurs(range.commonAncestorContainer) && document.body.contains(range.commonAncestorContainer)
          ? norm(range.toString()).trim() : '';
        if (!text) { return null; }
        var prefix = textBefore(range), suffix = textAfter(range);
        if (text.length <= MAX_QUOTE) { return { start: { quote: text, prefix: prefix, suffix: suffix } }; }
        return { start: { quote: text.slice(0, HALF).trim(), prefix: prefix, suffix: '' },
                 end: { quote: text.slice(-HALF).trim(), prefix: '', suffix: suffix } };
      }
      function report() {
        var now = snapshot();
        if (!now) {
          if (last !== '') { last = ''; post({ type: 'clear' }); }
          return;
        }
        var key = JSON.stringify(now);
        if (key === last) { return; }
        last = key;
        post({ type: 'select', start: now.start, end: now.end });
      }
      document.addEventListener('selectionchange', function () {
        clearTimeout(timer);
        timer = setTimeout(report, 150);
      });

      // Finding a quote again: the page's text, its text nodes and where each starts in it.
      function textIndex() {
        var nodes = [], starts = [], full = '';
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode: function (node) {
            var parent = node.parentElement;
            if (!parent) { return NodeFilter.FILTER_REJECT; }
            var tag = parent.tagName;
            if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || isOurs(parent)) { return NodeFilter.FILTER_REJECT; }
            return NodeFilter.FILTER_ACCEPT;
          }
        });
        var node;
        while ((node = walker.nextNode())) { nodes.push(node); starts.push(full.length); full += node.data; }
        return { nodes: nodes, starts: starts, full: full };
      }
      function escapeRegExp(text) { return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
      function pattern(quote) {
        var words = quote.trim().split(/\s+/).filter(function (w) { return w.length > 0; });
        return words.length ? new RegExp(words.map(escapeRegExp).join('\\s+'), 'g') : null;
      }
      // How well the words around a match agree with the quote's own: the best match wins, the first among equals.
      function score(index, start, end, prefix, suffix) {
        var before = norm(index.full.slice(Math.max(0, start - CONTEXT * 3), start)).trim();
        var after = norm(index.full.slice(end, end + CONTEXT * 3)).trim();
        var points = 0, p = (prefix || '').trim(), s = (suffix || '').trim();
        if (p) { points += before.endsWith(p) ? 2 : (before.endsWith(p.slice(-8)) ? 1 : 0); }
        if (s) { points += after.startsWith(s) ? 2 : (after.startsWith(s.slice(0, 8)) ? 1 : 0); }
        return points;
      }
      function find(index, q, from) {
        var re = q && q.quote ? pattern(q.quote) : null;
        if (!re) { return null; }
        re.lastIndex = from || 0;
        var best = null, match, guard = 0;
        while ((match = re.exec(index.full)) && guard++ < 500) {
          var found = { start: match.index, end: match.index + match[0].length };
          found.score = score(index, found.start, found.end, q.prefix, q.suffix);
          if (!best || found.score > best.score) { best = found; }
          if (match[0].length === 0) { re.lastIndex++; }
        }
        return best;
      }
      // The text node and offset at `offset` of the page's text; `atEnd` puts a boundary at the end of the node before it.
      function position(index, offset, atEnd) {
        var low = 0, high = index.starts.length - 1, found = 0;
        while (low <= high) {
          var mid = (low + high) >> 1;
          if (index.starts[mid] < offset || (!atEnd && index.starts[mid] === offset)) { found = mid; low = mid + 1; } else { high = mid - 1; }
        }
        var node = index.nodes[found];
        if (!node) { return null; }
        return { node: node, offset: Math.min(node.data.length, Math.max(0, offset - index.starts[found])) };
      }
      function rangeOf(selection, index) {
        var start = find(index, selection.start, 0);
        if (!start) { return null; }
        var endOffset = start.end;
        if (selection.end) {
          var end = find(index, selection.end, start.start);
          if (!end) { return null; }
          endOffset = end.end;
        }
        var a = position(index, start.start, false), b = position(index, endOffset, true);
        if (!a || !b) { return null; }
        var range = document.createRange();
        range.setStart(a.node, a.offset);
        range.setEnd(b.node, b.offset);
        return range;
      }

      // Drawing: highlights through CSS.highlights (no change to the page), tags in a shadow root of our own.
      function layer() {
        if (host && host.isConnected) { return root; }
        host = document.createElement('div');
        host.setAttribute('data-w42-shared', '');
        host.style.cssText = 'position:absolute;left:0;top:0;width:0;height:0;pointer-events:none;z-index:2147483647;';
        document.documentElement.appendChild(host);
        root = host.attachShadow({ mode: 'open' });
        return root;
      }
      function sheet() {
        if (styleSheet && styleSheet.isConnected) { return styleSheet; }
        styleSheet = document.createElement('style');
        styleSheet.setAttribute('data-w42-shared', '');
        (document.head || document.documentElement).appendChild(styleSheet);
        return styleSheet;
      }
      function draw() {
        if (!document.body) { return; }
        var shadow = layer(), css = '', highlights = window.CSS && CSS.highlights && window.Highlight;
        shadow.innerHTML = '';
        if (highlights) {
          Array.from(CSS.highlights.keys()).forEach(function (key) { if (key.indexOf('w42s') === 0) { CSS.highlights.delete(key); } });
        }
        var index = current.length ? textIndex() : null;
        current.forEach(function (selection, i) {
          var range = null;
          try { range = rangeOf(selection, index); } catch (e) { range = null; }
          if (!range) { return; }
          var rects = Array.from(range.getClientRects()).filter(function (r) { return r.width > 0 && r.height > 0; });
          if (!rects.length) { return; }
          if (highlights) {
            CSS.highlights.set('w42s' + i, new Highlight(range));
            css += '::highlight(w42s' + i + '){background-color:' + selection.fill + ';}';
          } else {
            rects.forEach(function (r) {
              var box = document.createElement('div');
              box.style.cssText = 'position:absolute;left:' + (r.left + window.scrollX) + 'px;top:' + (r.top + window.scrollY) +
                'px;width:' + r.width + 'px;height:' + r.height + 'px;background:' + selection.fill + ';border-radius:2px;';
              shadow.appendChild(box);
            });
          }
          // Their dart at the end of what they selected, its tip on the last character, and their name at its tail: the same
          // stemless dart every pointer is drawn with.
          var lastRect = rects[rects.length - 1];
          var tipX = lastRect.right + window.scrollX, tipY = lastRect.top + window.scrollY + lastRect.height * 0.5;
          var dart = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
          dart.setAttribute('width', '18');
          dart.setAttribute('height', '21');
          dart.setAttribute('viewBox', '0 0 20 23');
          dart.style.cssText = 'position:absolute;overflow:visible;left:' + (tipX - 2.7) + 'px;top:' + (tipY - 2.25) + 'px;';
          var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
          path.setAttribute('d', 'M3 2.5 L3 20.5 L8.8 15.6 L16.8 15.2 Z');
          path.setAttribute('fill', selection.color);
          path.setAttribute('stroke', 'white');
          path.setAttribute('stroke-width', '1.6');
          path.setAttribute('stroke-linejoin', 'round');
          dart.appendChild(path);
          shadow.appendChild(dart);
          var tag = document.createElement('div');
          tag.textContent = selection.name;
          tag.style.cssText = 'position:absolute;left:' + (tipX + 11) + 'px;top:' + (tipY + 13) +
            'px;padding:1px 6px;border-radius:999px;background:' + selection.color +
            ';color:#fff;font:600 10px -apple-system,system-ui,sans-serif;line-height:15px;white-space:nowrap;';
          shadow.appendChild(tag);
        });
        sheet().textContent = css;
      }
      var redraw = null;
      window.addEventListener('resize', function () { clearTimeout(redraw); redraw = setTimeout(draw, 100); });
      window.__w42Shared = {
        show: function (selections) { current = selections || []; draw(); },
        // What is selected now, as JSON ('null' for nothing): read by the host on its own beat, so a selection change no event
        // reported (or one whose message was lost) still reaches the others.
        snapshot: function () { return JSON.stringify(snapshot()); }
      };
      post({ type: 'ready' });
    })();
    """#
}

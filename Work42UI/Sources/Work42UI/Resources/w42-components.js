/* w42-components.js — the <w42-*> tag runtime.
 *
 * Each tag is a custom element that expands, in the light DOM, to the
 * `.w42-*` classes in w42-components.css. Tags are the agent-facing API; the
 * classes stay available underneath. The legacy upgraders in the shell
 * (w42-code, w42-table, w42-mockup) live in componentsJS and are not
 * redefined here.
 *
 * Contract:
 *   - define(tag, { render(host, ctx) }) registers one tag, once.
 *   - rendering is idempotent: a host is marked data-w42-ready and never
 *     rendered twice.
 *   - a failing render logs `w42 component error [<tag>]: <message>` (the
 *     overlay shows console errors) and leaves the host's content untouched.
 *   - an unknown <w42-*> tag logs `w42 component error [<tag>]: unknown
 *     component` so a typo is visible, not silently unstyled.
 */
(function () {
  "use strict";
  if (window.__w42 && window.__w42.components) { return; }

  // Tags handled by the shell's own upgraders, not by this file.
  var LEGACY = { "w42-code": 1, "w42-table": 1, "w42-mockup": 1, "w42-flutter-mockup": 1 };
  var registry = {};

  function fail(tag, err) {
    if (window.console && console.error) {
      console.error("w42 component error [" + tag + "]: " + String((err && err.message) || err));
    }
  }

  function el(name, cls, text) {
    var n = document.createElement(name);
    if (cls) { n.className = cls; }
    if (text != null) { n.textContent = text; }
    return n;
  }

  function addClass(host, cls) {
    String(cls).split(/\s+/).forEach(function (c) { if (c) { host.classList.add(c); } });
  }

  function attr(host, name, fallback) {
    var v = host.getAttribute(name);
    return v == null ? fallback : v;
  }

  function flag(host, name) {
    var v = host.getAttribute(name);
    return v != null && v !== "false";
  }

  function iconNode(glyph) {
    var s = el("span", "w42-icon", glyph);
    s.setAttribute("aria-hidden", "true");
    return s;
  }

  function define(tag, spec) {
    registry[tag] = spec;
    if (!window.customElements || window.customElements.get(tag)) { return; }
    function run(host) {
      if (host.getAttribute("data-w42-ready")) { return; }
      host.setAttribute("data-w42-ready", "1");
      try { spec.render(host); }
      catch (err) { fail(tag, err); }
    }
    var C = class extends HTMLElement {
      connectedCallback() {
        // Parser-created hosts can connect before their children exist.
        if (document.readyState === "loading") {
          var self = this;
          document.addEventListener("DOMContentLoaded", function () { run(self); });
        } else { run(this); }
      }
    };
    window.customElements.define(tag, C);
  }

  function keyActivate(host) {
    host.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.key === " ") { e.preventDefault(); host.click(); }
    });
  }

  /* — <w42-button variant="prominent|glass|plain|destructive" icon="" icon-only disabled> — */
  define("w42-button", {
    render: function (host) {
      addClass(host, "w42-button");
      var variant = attr(host, "variant", "");
      if (variant) { addClass(host, "w42-button-" + variant); }
      var glyph = attr(host, "icon", "");
      if (glyph) { host.insertBefore(iconNode(glyph), host.firstChild); }
      if (flag(host, "icon-only")) { addClass(host, "w42-button-icon"); }
      host.setAttribute("role", "button");
      host.setAttribute("tabindex", flag(host, "disabled") ? "-1" : "0");
      if (flag(host, "disabled")) { host.setAttribute("aria-disabled", "true"); }
      keyActivate(host);
    }
  });

  /* — <w42-tabs><w42-tab label="" badge="" selected disabled></w42-tab></w42-tabs> — */
  define("w42-tabs", {
    render: function (host) {
      addClass(host, "w42-tabs");
      host.setAttribute("role", "tablist");
      host.addEventListener("click", function (e) {
        var tab = e.target.closest ? e.target.closest("w42-tab") : null;
        if (!tab || !host.contains(tab) || tab.getAttribute("aria-disabled") === "true") { return; }
        var tabs = host.querySelectorAll("w42-tab");
        for (var i = 0; i < tabs.length; i++) {
          tabs[i].setAttribute("aria-selected", tabs[i] === tab ? "true" : "false");
          tabs[i].setAttribute("tabindex", tabs[i] === tab ? "0" : "-1");
        }
        host.dispatchEvent(new CustomEvent("w42-select", {
          bubbles: true, detail: { label: tab.getAttribute("label") || tab.textContent.trim() }
        }));
      });
    }
  });
  define("w42-tab", {
    render: function (host) {
      addClass(host, "w42-tab");
      var label = attr(host, "label", "");
      if (label) { host.textContent = label; }
      var badge = attr(host, "badge", "");
      if (badge) { host.appendChild(el("span", "w42-tab-badge", badge)); }
      var selected = flag(host, "selected");
      host.setAttribute("role", "tab");
      host.setAttribute("aria-selected", selected ? "true" : "false");
      host.setAttribute("tabindex", selected ? "0" : "-1");
      if (flag(host, "disabled")) { host.setAttribute("aria-disabled", "true"); }
      keyActivate(host);
    }
  });

  /* — <w42-toolbar> holding <w42-button>, <w42-tabs> and <w42-sep> — */
  define("w42-toolbar", {
    render: function (host) {
      addClass(host, "w42-toolbar");
      host.setAttribute("role", "toolbar");
    }
  });
  define("w42-sep", {
    render: function (host) {
      addClass(host, "w42-toolbar-sep");
      host.setAttribute("role", "separator");
    }
  });

  /* — <w42-chip tone="success|warning|failure|accent" icon=""> — */
  define("w42-chip", {
    render: function (host) {
      addClass(host, "w42-chip");
      var tone = attr(host, "tone", "");
      if (tone) { addClass(host, "w42-chip-" + tone); }
      var glyph = attr(host, "icon", "");
      if (glyph) { host.insertBefore(iconNode(glyph), host.firstChild); }
    }
  });

  /* — <w42-section-header title="" sub="">right-side content</w42-section-header> — */
  define("w42-section-header", {
    render: function (host) {
      addClass(host, "w42-section-header");
      var kids = Array.prototype.slice.call(host.childNodes);
      host.textContent = "";
      host.appendChild(el("h2", "w42-section-header-title", attr(host, "title", "")));
      if (kids.length) {
        var right = el("div", "w42-section-header-right");
        kids.forEach(function (k) { right.appendChild(k); });
        host.appendChild(right);
      }
      var sub = attr(host, "sub", "");
      if (sub) { host.appendChild(el("p", "w42-section-header-sub", sub)); }
      host.removeAttribute("title");
    }
  });

  /* — <w42-empty title="" icon="">body text and actions</w42-empty> — */
  define("w42-empty", {
    render: function (host) {
      addClass(host, "w42-empty");
      var kids = Array.prototype.slice.call(host.childNodes);
      host.textContent = "";
      var glyph = attr(host, "icon", "");
      if (glyph) { host.appendChild(iconNode(glyph)); }
      host.appendChild(el("p", "w42-empty-title", attr(host, "title", "Nothing here yet")));
      var body = el("div", "w42-empty-body");
      kids.forEach(function (k) { body.appendChild(k); });
      if (body.childNodes.length) { host.appendChild(body); }
      host.removeAttribute("title");
    }
  });

  /* — <w42-loading label=""> and <w42-spinner> — */
  define("w42-spinner", {
    render: function (host) {
      addClass(host, "w42-spinner");
      host.setAttribute("role", "progressbar");
      host.setAttribute("aria-label", attr(host, "label", "Loading"));
    }
  });
  define("w42-loading", {
    render: function (host) {
      addClass(host, "w42-loading");
      var label = attr(host, "label", "Loading");
      host.textContent = "";
      host.appendChild(el("span", "w42-spinner"));
      host.appendChild(el("span", "", label));
      host.setAttribute("role", "status");
    }
  });

  /* — <w42-progress value="0..100" circular> — omit value for indeterminate — */
  define("w42-progress", {
    render: function (host) {
      var circular = flag(host, "circular");
      var raw = host.getAttribute("value");
      var value = raw == null ? null : Math.max(0, Math.min(100, parseFloat(raw) || 0));
      host.setAttribute("role", "progressbar");
      host.setAttribute("aria-valuemin", "0");
      host.setAttribute("aria-valuemax", "100");
      if (value == null) {
        host.textContent = "";
        addClass(host, "w42-spinner");
        return;
      }
      host.setAttribute("aria-valuenow", String(value));
      if (circular) {
        addClass(host, "w42-progress-circular");
        host.style.setProperty("--w42-progress", String(value));
      } else {
        addClass(host, "w42-progress");
        host.textContent = "";
        var bar = el("span");
        bar.style.setProperty("--w42-progress", value + "%");
        host.appendChild(bar);
      }
    }
  });

  /* — <w42-field label="" hint="">any control</w42-field> — */
  define("w42-field", {
    render: function (host) {
      addClass(host, "w42-field");
      var label = attr(host, "label", "");
      if (label) { host.insertBefore(el("label", "w42-field-label", label), host.firstChild); }
      var hint = attr(host, "hint", "");
      if (hint) { host.appendChild(el("div", "w42-field-hint", hint)); }
    }
  });

  /* — <w42-disclosure title="" open>content</w42-disclosure> — */
  define("w42-disclosure", {
    render: function (host) {
      var kids = Array.prototype.slice.call(host.childNodes);
      host.textContent = "";
      var d = el("details", "w42-disclosure");
      if (flag(host, "open")) { d.open = true; }
      d.appendChild(el("summary", "", attr(host, "title", "Details")));
      kids.forEach(function (k) { d.appendChild(k); });
      host.appendChild(d);
      host.removeAttribute("title");
    }
  });

  /* — <w42-card title="">content</w42-card> and <w42-group title=""> — */
  define("w42-card", {
    render: function (host) {
      addClass(host, "w42-card");
      var title = attr(host, "title", "");
      if (title) {
        var head = el("div", "w42-section-header");
        head.appendChild(el("h3", "w42-section-header-title", title));
        host.insertBefore(head, host.firstChild);
        host.removeAttribute("title");
      }
    }
  });
  define("w42-group", {
    render: function (host) {
      addClass(host, "w42-group");
      var title = attr(host, "title", "");
      if (title) {
        host.insertBefore(el("div", "w42-group-title", title), host.firstChild);
        host.removeAttribute("title");
      }
    }
  });

  /* — <w42-list><w42-row title="" detail="" icon="" selected>nested rows</w42-row></w42-list>
       Nested <w42-row> elements indent one level each, up to level 4. — */
  define("w42-list", {
    render: function (host) {
      addClass(host, "w42-list");
      host.setAttribute("role", "tree");
    }
  });
  define("w42-row", {
    render: function (host) {
      var depth = 0;
      for (var p = host.parentElement; p; p = p.parentElement) {
        if (p.localName === "w42-row") { depth++; }
      }
      depth = Math.min(depth, 4);
      var kids = Array.prototype.filter.call(host.children, function (c) { return c.localName === "w42-row"; });
      var line = el("div", "w42-list-row");
      line.setAttribute("data-depth", String(depth));
      if (kids.length) { line.setAttribute("data-has-children", ""); }
      if (flag(host, "selected")) { line.classList.add("is-selected"); line.setAttribute("aria-selected", "true"); }
      var glyph = attr(host, "icon", "");
      if (glyph) { line.appendChild(iconNode(glyph)); }
      line.appendChild(el("span", "w42-list-row-title", attr(host, "title", "")));
      var detail = attr(host, "detail", "");
      if (detail) { line.appendChild(el("span", "w42-list-row-detail", detail)); }
      host.setAttribute("role", "treeitem");
      host.style.display = "contents";
      host.insertBefore(line, host.firstChild);
      host.removeAttribute("title");
    }
  });

  /* — <w42-metric label="" value="" delta="" tone="up|down"> — */
  define("w42-metric", {
    render: function (host) {
      addClass(host, "w42-metric");
      host.textContent = "";
      host.appendChild(el("span", "w42-metric-label", attr(host, "label", "")));
      host.appendChild(el("span", "w42-metric-value", attr(host, "value", "")));
      var delta = attr(host, "delta", "");
      if (delta) {
        var tone = attr(host, "tone", "");
        host.appendChild(el("span", "w42-metric-delta" + (tone ? " w42-metric-delta-" + tone : ""), delta));
      }
    }
  });

  /* — <w42-callout tone="info|success|warning|failure" title="">body</w42-callout> — */
  var CALLOUT_GLYPH = { info: "i", success: "\u2713", warning: "!", failure: "\u00d7" };
  define("w42-callout", {
    render: function (host) {
      var tone = attr(host, "tone", "info");
      if (!CALLOUT_GLYPH[tone]) { throw new Error("tone must be info, success, warning or failure (got \"" + tone + "\")"); }
      addClass(host, "w42-callout w42-callout-icon w42-callout-" + tone);
      var kids = Array.prototype.slice.call(host.childNodes);
      host.textContent = "";
      var ico = el("span", "w42-callout-icon-ico", CALLOUT_GLYPH[tone]);
      ico.setAttribute("aria-hidden", "true");
      var body = el("div");
      var title = attr(host, "title", "");
      if (title) { body.appendChild(el("span", "w42-callout-icon-label", title)); }
      kids.forEach(function (k) { body.appendChild(k); });
      host.appendChild(ico);
      host.appendChild(body);
      host.setAttribute("role", "note");
      host.removeAttribute("title");
    }
  });

  /* ── Overlays ─────────────────────────────────────────────────────── */

  function target(tag, host) {
    var id = host.getAttribute("for");
    var node = id ? document.getElementById(id) : null;
    if (!node) { throw new Error("no element #" + (id || "(missing for attribute)")); }
    return node;
  }

  var openOverlay = null; // the one popover or menu currently open

  function place(host, trigger, edge) {
    var t = trigger.getBoundingClientRect();
    host.style.left = "0px"; host.style.top = "0px";
    var h = host.getBoundingClientRect();
    var gap = 10, x, y;
    if (edge === "bottom") { x = t.left + t.width / 2 - h.width / 2; y = t.top - h.height - gap; }
    else if (edge === "leading") { x = t.right + gap; y = t.top + t.height / 2 - h.height / 2; }
    else if (edge === "trailing") { x = t.left - h.width - gap; y = t.top + t.height / 2 - h.height / 2; }
    else { x = t.left + t.width / 2 - h.width / 2; y = t.bottom + gap; }
    var vw = document.documentElement.clientWidth, vh = document.documentElement.clientHeight;
    host.style.left = Math.max(8, Math.min(x, vw - h.width - 8)) + "px";
    host.style.top = Math.max(8, Math.min(y, vh - h.height - 8)) + "px";
  }

  function closeOverlay(host, restore) {
    if (!host.hasAttribute("data-open")) { return; }
    host.removeAttribute("data-open");
    try { if (host.hidePopover && host.matches(":popover-open")) { host.hidePopover(); } } catch (e) {}
    if (openOverlay === host) { openOverlay = null; }
    if (restore && host.__w42trigger && host.__w42trigger.focus) { host.__w42trigger.focus(); }
  }

  function openPanel(host, trigger, edge, focusSel) {
    if (openOverlay && openOverlay !== host) { closeOverlay(openOverlay, false); }
    host.setAttribute("data-open", "");
    openOverlay = host;
    if (host.showPopover) { try { host.showPopover(); } catch (e) {} }
    place(host, trigger, edge);
    var first = host.querySelector(focusSel);
    if (first) { first.focus(); } else { host.setAttribute("tabindex", "-1"); host.focus(); }
  }

  function wireOverlay(tag, host, edge, focusSel) {
    var trigger = target(tag, host);
    host.__w42trigger = trigger;
    if (host.showPopover) { host.setAttribute("popover", "auto"); }
    trigger.addEventListener("click", function (e) {
      e.stopPropagation();
      if (host.hasAttribute("data-open")) { closeOverlay(host, true); }
      else { openPanel(host, trigger, edge, focusSel); }
    });
    // Fallback and belt-and-braces for the Popover API's own light dismiss.
    document.addEventListener("click", function (e) {
      if (host.hasAttribute("data-open") && !host.contains(e.target) && !trigger.contains(e.target)) {
        closeOverlay(host, false);
      }
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && host.hasAttribute("data-open")) { closeOverlay(host, true); }
    });
    host.addEventListener("toggle", function (e) {
      if (e.newState === "closed" && host.hasAttribute("data-open")) { host.removeAttribute("data-open"); }
    });
    window.addEventListener("resize", function () { if (host.hasAttribute("data-open")) { place(host, trigger, edge); } });
  }

  /* — <w42-popover for="" edge="top|bottom|leading|trailing"> — */
  define("w42-popover", {
    render: function (host) {
      addClass(host, "w42-popover");
      var edge = attr(host, "edge", "top");
      if (["top", "bottom", "leading", "trailing"].indexOf(edge) < 0) { throw new Error("edge must be top, bottom, leading or trailing"); }
      host.setAttribute("data-edge", edge);
      host.setAttribute("role", "dialog");
      wireOverlay("w42-popover", host, edge, "button, [role=button], input, select, textarea, a[href]");
    }
  });

  /* — <w42-menu for=""><w42-menu-item value="" shortcut="" disabled>…</w42-menu-item><hr></w42-menu> — */
  function menuItems(host) {
    return Array.prototype.filter.call(host.querySelectorAll("w42-menu-item"), function (i) {
      return i.getAttribute("aria-disabled") !== "true";
    });
  }
  define("w42-menu", {
    render: function (host) {
      addClass(host, "w42-menu");
      host.setAttribute("role", "menu");
      wireOverlay("w42-menu", host, "top", "w42-menu-item:not([aria-disabled=true])");
      host.addEventListener("keydown", function (e) {
        var items = menuItems(host), i = items.indexOf(document.activeElement);
        if (e.key === "ArrowDown") { e.preventDefault(); items[(i + 1) % items.length].focus(); }
        else if (e.key === "ArrowUp") { e.preventDefault(); items[(i - 1 + items.length) % items.length].focus(); }
        else if (e.key === "Enter" && i >= 0) { e.preventDefault(); items[i].click(); }
      });
      host.addEventListener("click", function (e) {
        var item = e.target.closest ? e.target.closest("w42-menu-item") : null;
        if (!item || item.getAttribute("aria-disabled") === "true") { return; }
        host.dispatchEvent(new CustomEvent("w42-select", {
          bubbles: true, detail: { value: item.getAttribute("value") || item.textContent.trim() }
        }));
        closeOverlay(host, true);
      });
    }
  });
  define("w42-menu-item", {
    render: function (host) {
      addClass(host, "w42-menu-item");
      host.setAttribute("role", "menuitem");
      host.setAttribute("tabindex", "-1");
      if (flag(host, "disabled")) { host.setAttribute("aria-disabled", "true"); }
      var sc = attr(host, "shortcut", "");
      if (sc) { host.appendChild(el("span", "w42-menu-item-shortcut", sc)); }
    }
  });
  define("w42-menu-label", { render: function (host) { addClass(host, "w42-menu-label"); } });

  /* — [data-tooltip]: one shared node, shown after 500 ms of hover or focus — */
  (function () {
    var tip = null, timer = null;
    function node() {
      if (!tip) {
        tip = el("div", "w42-tooltip");
        tip.setAttribute("role", "tooltip");
        document.body.appendChild(tip);
      }
      return tip;
    }
    function hide() {
      clearTimeout(timer);
      if (tip) { tip.removeAttribute("data-open"); }
    }
    function show(t) {
      var n = node();
      n.textContent = t.getAttribute("data-tooltip");
      n.setAttribute("data-open", "");
      var r = t.getBoundingClientRect(), b = n.getBoundingClientRect();
      var vw = document.documentElement.clientWidth;
      n.style.left = Math.max(4, Math.min(r.left + r.width / 2 - b.width / 2, vw - b.width - 4)) + "px";
      n.style.top = (r.bottom + 6) + "px";
    }
    function arm(e) {
      var t = e.target.closest ? e.target.closest("[data-tooltip]") : null;
      if (!t) { return; }
      clearTimeout(timer);
      timer = setTimeout(function () { show(t); }, 500);
    }
    function disarm(e) {
      var t = e.target.closest ? e.target.closest("[data-tooltip]") : null;
      if (t) { hide(); }
    }
    function init() {
      document.addEventListener("mouseover", arm);
      document.addEventListener("focusin", arm);
      document.addEventListener("mouseout", disarm);
      document.addEventListener("focusout", disarm);
      document.addEventListener("keydown", function (e) { if (e.key === "Escape") { hide(); } });
    }
    if (document.readyState === "loading") { document.addEventListener("DOMContentLoaded", init); } else { init(); }
  })();

  /* — <w42-dialog for="" title="" layout="side|stacked"> and <w42-sheet for=""> — */
  function modal(tag, host, cls) {
    var trigger = target(tag, host);
    var kids = Array.prototype.slice.call(host.childNodes);
    host.textContent = "";
    var d = document.createElement("dialog");
    d.className = cls;
    var title = attr(host, "title", "");
    if (title) { d.appendChild(el("h2", "w42-dialog-title", title)); }
    var body = el("div", "w42-dialog-body");
    var actions = el("div", "w42-dialog-actions");
    kids.forEach(function (k) {
      var isBtn = k.nodeType === 1 && (k.localName === "w42-button" || k.localName === "button");
      (isBtn ? actions : body).appendChild(k);
    });
    if (body.childNodes.length) { d.appendChild(body); }
    if (actions.childNodes.length) { d.appendChild(actions); }
    if (attr(host, "layout", "") === "stacked") { d.classList.add("w42-dialog-stacked"); }
    host.appendChild(d);
    host.removeAttribute("title");
    trigger.addEventListener("click", function () {
      if (d.open) { return; }
      if (d.showModal) { d.showModal(); } else { d.setAttribute("open", ""); }
    });
    d.addEventListener("click", function (e) {
      var c = e.target.closest ? e.target.closest("[data-close]") : null;
      if (c && d.contains(c)) { if (d.close) { d.close(); } else { d.removeAttribute("open"); } }
    });
    return d;
  }
  define("w42-dialog", { render: function (host) { modal("w42-dialog", host, "w42-dialog"); } });
  define("w42-sheet", { render: function (host) { modal("w42-sheet", host, "w42-sheet"); } });

  /* — <w42-toast tone="" title=""> and window.w42.toast({title, message, tone}) — */
  var TOAST_GLYPH = { info: "i", success: "✓", warning: "!", failure: "×" };
  function toastRegion() {
    var r = document.querySelector(".w42-toast-region");
    if (!r) { r = el("div", "w42-toast-region"); r.setAttribute("aria-live", "polite"); document.body.appendChild(r); }
    return r;
  }
  define("w42-toast", {
    render: function (host) {
      var tone = attr(host, "tone", "info");
      if (!TOAST_GLYPH[tone]) { throw new Error("tone must be info, success, warning or failure (got \"" + tone + "\")"); }
      addClass(host, "w42-toast w42-toast-" + tone);
      var kids = Array.prototype.slice.call(host.childNodes);
      host.textContent = "";
      var glyph = el("span", "w42-toast-glyph", TOAST_GLYPH[tone]);
      glyph.setAttribute("aria-hidden", "true");
      var text = el("div");
      var title = attr(host, "title", "");
      if (title) { text.appendChild(el("span", "w42-toast-title", title)); }
      kids.forEach(function (k) { text.appendChild(k); });
      var close = el("button", "w42-toast-close", "✕");
      close.type = "button";
      close.setAttribute("aria-label", "Dismiss");
      host.appendChild(glyph); host.appendChild(text); host.appendChild(close);
      host.removeAttribute("title");
      host.setAttribute("role", "status");
      toastRegion().appendChild(host);
      var timer = null;
      function dismiss() { clearTimeout(timer); if (host.parentNode) { host.parentNode.removeChild(host); } }
      function arm() { clearTimeout(timer); timer = setTimeout(dismiss, 5000); }
      close.addEventListener("click", dismiss);
      host.addEventListener("mouseenter", function () { clearTimeout(timer); });
      host.addEventListener("mouseleave", arm);
      arm();
    }
  });
  window.w42 = window.w42 || {};
  window.w42.toast = function (opts) {
    opts = opts || {};
    var t = document.createElement("w42-toast");
    t.setAttribute("tone", opts.tone || "info");
    if (opts.title) { t.setAttribute("title", opts.title); }
    if (opts.message) { t.textContent = opts.message; }
    document.body.appendChild(t);
    return t;
  };

  function reportUnknown(root) {
    var all = root.querySelectorAll ? root.querySelectorAll("*") : [];
    for (var i = 0; i < all.length; i++) {
      var tag = all[i].localName;
      if (tag.indexOf("w42-") !== 0 || registry[tag] || LEGACY[tag]) { continue; }
      if (all[i].getAttribute("data-w42-unknown")) { continue; }
      all[i].setAttribute("data-w42-unknown", "1");
      fail(tag, "unknown component");
    }
  }

  function watch() {
    reportUnknown(document);
    if (!window.MutationObserver) { return; }
    new MutationObserver(function (muts) {
      muts.forEach(function (m) {
        for (var i = 0; i < m.addedNodes.length; i++) {
          var n = m.addedNodes[i];
          if (n.nodeType !== 1) { continue; }
          if (n.localName.indexOf("w42-") === 0 && !registry[n.localName] && !LEGACY[n.localName]) {
            if (!n.getAttribute("data-w42-unknown")) {
              n.setAttribute("data-w42-unknown", "1");
              fail(n.localName, "unknown component");
            }
          }
          reportUnknown(n);
        }
      });
    }).observe(document.documentElement, { childList: true, subtree: true });
  }

  window.__w42 = window.__w42 || {};
  window.__w42.components = { define: define, registry: registry, legacy: LEGACY };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", watch);
  } else { watch(); }
})();

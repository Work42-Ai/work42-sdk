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

  // An enumerated attribute: an invalid value logs the documented component error
  // and falls back to the default (AC11), so the tag still renders.
  function enumAttr(tag, host, name, allowed, fallback) {
    var v = host.getAttribute(name);
    if (v == null || v === "") { return fallback; }
    if (allowed.indexOf(v) < 0) {
      fail(tag, name + " must be " + allowed.join(", ") + " (got \"" + v + "\")");
      return fallback;
    }
    return v;
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

  /* — <w42-button variant="solid|bordered|glass|menu" icon="" icon-only disabled> — */
  define("w42-button", {
    render: function (host) {
      addClass(host, "w42-button");
      var variant = enumAttr("w42-button", host, "variant", ["solid", "bordered", "glass", "menu"], "bordered");
      addClass(host, "w42-button-" + variant);
      var glyph = attr(host, "icon", "");
      if (glyph) { host.insertBefore(iconNode(glyph), host.firstChild); }
      if (flag(host, "icon-only")) { addClass(host, "w42-button-icon"); }
      host.setAttribute("role", "button");
      host.setAttribute("tabindex", flag(host, "disabled") ? "-1" : "0");
      if (flag(host, "disabled")) { host.setAttribute("aria-disabled", "true"); }
      keyActivate(host);
    }
  });

  /* — <w42-tabs><w42-tab label="" badge="" selected disabled>panel</w42-tab></w42-tabs>
       The strip is a glass capsule; a tab's content is its panel, shown below. — */
  function selectTab(set, tab, focus) {
    set.__w42tabs.forEach(function (t) {
      var on = t.el === tab;
      t.el.setAttribute("aria-selected", on ? "true" : "false");
      t.el.setAttribute("tabindex", on ? "0" : "-1");
      if (t.panel) { t.panel.hidden = !on; }
    });
    if (focus && tab.focus) { tab.focus(); }
    var pill = set.__w42pill;
    if (pill && tab.offsetWidth) {
      pill.style.width = tab.offsetWidth + "px";
      pill.style.transform = "translateX(" + tab.offsetLeft + "px)";
    }
  }
  define("w42-tabs", {
    render: function (host) {
      addClass(host, "w42-tabset");
      var els = Array.prototype.filter.call(host.children, function (c) { return c.localName === "w42-tab"; });
      var strip = el("div", "w42-tabs");
      strip.setAttribute("role", "tablist");
      var entries = [], panels = [];
      els.forEach(function (tab) {
        tab.setAttribute("data-w42-ready", "1");
        var kids = Array.prototype.slice.call(tab.childNodes);
        tab.textContent = "";
        addClass(tab, "w42-tab");
        tab.appendChild(document.createTextNode(attr(tab, "label", "")));
        var badge = attr(tab, "badge", "");
        if (badge) { tab.appendChild(el("span", "w42-tab-badge", badge)); }
        tab.setAttribute("role", "tab");
        if (flag(tab, "disabled")) { tab.setAttribute("aria-disabled", "true"); }
        keyActivate(tab);
        var panel = null;
        var hasContent = kids.some(function (k) { return k.nodeType === 1 || (k.nodeType === 3 && k.nodeValue.trim()); });
        if (hasContent) {
          panel = el("div", "w42-tab-panel");
          panel.setAttribute("role", "tabpanel");
          kids.forEach(function (k) { panel.appendChild(k); });
          panels.push(panel);
        }
        entries.push({ el: tab, panel: panel });
        strip.appendChild(tab);
      });
      host.textContent = "";
      host.appendChild(strip);
      panels.forEach(function (p) { host.appendChild(p); });
      host.__w42tabs = entries;
      var pill = el("span", "w42-tab-pill");
      strip.insertBefore(pill, strip.firstChild);
      addClass(strip, "w42-tabs-glide");
      host.__w42pill = pill;
      var live = entries.filter(function (e) { return e.el.getAttribute("aria-disabled") !== "true"; });
      var initial = (live.filter(function (e) { return flag(e.el, "selected"); })[0] || live[0]);
      if (initial) { selectTab(host, initial.el, false); }
      // Fonts and layout settle after first paint; re-seat the pill then.
      function reseat() {
        var cur = entries.filter(function (e) { return e.el.getAttribute("aria-selected") === "true"; })[0];
        if (cur) { selectTab(host, cur.el, false); }
      }
      if (window.requestAnimationFrame) { window.requestAnimationFrame(reseat); }
      window.addEventListener("resize", reseat);
      function choose(tab, focus) {
        if (tab.getAttribute("aria-disabled") === "true") { return; }
        selectTab(host, tab, focus);
        host.dispatchEvent(new CustomEvent("w42-select", {
          bubbles: true, detail: { label: tab.getAttribute("label") || tab.textContent.trim() }
        }));
      }
      strip.addEventListener("click", function (e) {
        var tab = e.target.closest ? e.target.closest("w42-tab") : null;
        if (tab && strip.contains(tab)) { choose(tab, false); }
      });
      strip.addEventListener("keydown", function (e) {
        if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") { return; }
        var order = live.map(function (x) { return x.el; });
        var i = order.indexOf(document.activeElement);
        if (i < 0) { return; }
        e.preventDefault();
        var next = order[(i + (e.key === "ArrowRight" ? 1 : order.length - 1)) % order.length];
        choose(next, true);
      });
    }
  });
  // A w42-tab outside a w42-tabs just renders as a tab; w42-tabs builds its own.
  define("w42-tab", {
    render: function (host) {
      addClass(host, "w42-tab");
      var label = attr(host, "label", "");
      if (label) { host.textContent = label; }
      var badge = attr(host, "badge", "");
      if (badge) { host.appendChild(el("span", "w42-tab-badge", badge)); }
      host.setAttribute("role", "tab");
      host.setAttribute("aria-selected", flag(host, "selected") ? "true" : "false");
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
      var tone = enumAttr("w42-chip", host, "tone", ["neutral", "success", "warning", "failure", "accent"], "neutral");
      if (tone !== "neutral") { addClass(host, "w42-chip-" + tone); }
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
      var msg = attr(host, "message", "");
      if (msg) { body.appendChild(document.createTextNode(msg)); }
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

  /* — <w42-progress value="0..1" circular> — omit value for indeterminate — */
  define("w42-progress", {
    render: function (host) {
      var circular = flag(host, "circular");
      var raw = host.getAttribute("value");
      var value = null;
      if (raw != null && raw !== "") {
        var n = parseFloat(raw);
        if (isNaN(n) || n < 0 || n > 1) { fail("w42-progress", "value must be a number from 0 to 1 (got \"" + raw + "\")"); }
        else { value = n * 100; }
      }
      host.setAttribute("role", "progressbar");
      host.setAttribute("aria-valuemin", "0");
      host.setAttribute("aria-valuemax", "100");
      if (value == null) {
        host.textContent = "";
        addClass(host, "w42-spinner");
        return;
      }
      host.setAttribute("aria-valuenow", String(Math.round(value)));
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
        var tone = enumAttr("w42-metric", host, "tone", ["success", "failure", "up", "down"], "");
        var cls = { success: "up", up: "up", failure: "down", down: "down" }[tone];
        host.appendChild(el("span", "w42-metric-delta" + (cls ? " w42-metric-delta-" + cls : ""), delta));
      }
    }
  });

  /* — <w42-callout tone="info|success|warning|failure" title="">body</w42-callout> — */
  var CALLOUT_GLYPH = { info: "i", success: "\u2713", warning: "!", failure: "\u00d7" };
  define("w42-callout", {
    render: function (host) {
      var tone = enumAttr("w42-callout", host, "tone", ["info", "success", "warning", "failure"], "info");
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
      var edge = enumAttr("w42-popover", host, "edge", ["top", "bottom", "leading", "trailing"], "bottom");
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
      var tone = enumAttr("w42-toast", host, "tone", ["info", "success", "warning", "failure"], "info");
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

  /* ── Spec / doc ───────────────────────────────────────────────────── */

  function slug(text) {
    return String(text).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "section";
  }

  /* — <w42-hero eyebrow="a, b, c" title="" subtitle="">extra chips and buttons</w42-hero> — */
  define("w42-hero", {
    render: function (host) {
      addClass(host, "w42-hero");
      var kids = Array.prototype.slice.call(host.childNodes);
      host.textContent = "";
      var panel = el("div", "w42-hero-panel");
      var eyebrow = attr(host, "eyebrow", "");
      if (eyebrow) {
        var row = el("div", "w42-hero-eyebrow");
        eyebrow.split(",").forEach(function (t, i) {
          t = t.trim();
          if (t) { row.appendChild(el("span", "w42-chip" + (i === 0 ? " w42-chip-accent" : ""), t)); }
        });
        panel.appendChild(row);
      }
      panel.appendChild(el("h1", "w42-hero-title", attr(host, "title", "")));
      var sub = attr(host, "subtitle", "");
      if (sub) { panel.appendChild(el("p", "w42-hero-subtitle", sub)); }
      if (kids.length) {
        var extra = el("div", "w42-hero-extra");
        kids.forEach(function (k) { extra.appendChild(k); });
        panel.appendChild(extra);
      }
      host.appendChild(panel);
      host.removeAttribute("title");
    }
  });

  /* — <w42-section n="" title="" id="">content</w42-section> — */
  var sectionSeq = 0;
  define("w42-section", {
    render: function (host) {
      var title = attr(host, "title", "");
      if (!title) { throw new Error("title is required"); }
      var n = attr(host, "n", String(++sectionSeq));
      var id = attr(host, "id", slug(title));
      var kids = Array.prototype.slice.call(host.childNodes);
      host.textContent = "";
      var sec = document.createElement("section");
      sec.setAttribute("data-spec-section", id);
      sec.id = id;
      var head = el("div", "w42-shead");
      head.appendChild(el("span", "w42-shead-chip", n));
      head.appendChild(el("h2", "", title));
      head.appendChild(el("span", "w42-shead-rule"));
      sec.appendChild(head);
      kids.forEach(function (k) { sec.appendChild(k); });
      host.appendChild(sec);
      host.removeAttribute("id");
      host.removeAttribute("title");
      host.setAttribute("data-section-n", n);
      host.setAttribute("data-section-title", title);
      host.setAttribute("data-section-id", id);
      var tocs = document.querySelectorAll("w42-toc");
      for (var i = 0; i < tocs.length; i++) { if (tocs[i].__w42build) { tocs[i].__w42build(); } }
    }
  });

  /* — <w42-toc>: tab-strip links to every <w42-section>, the one in view selected — */
  define("w42-toc", {
    render: function (host) {
      addClass(host, "w42-toc");
      host.setAttribute("role", "navigation");
      var io = null;
      function build() {
        host.textContent = "";
        if (io) { io.disconnect(); io = null; }
        var secs = document.querySelectorAll("w42-section[data-section-id]");
        var links = {};
        for (var i = 0; i < secs.length; i++) {
          var s = secs[i], a = el("a");
          a.href = "#" + s.getAttribute("data-section-id");
          a.appendChild(el("span", "w42-toc-num", s.getAttribute("data-section-n")));
          a.appendChild(document.createTextNode(" " + s.getAttribute("data-section-title")));
          host.appendChild(a);
          links[s.getAttribute("data-section-id")] = a;
        }
        if (window.IntersectionObserver) {
          io = new IntersectionObserver(function (entries) {
            entries.forEach(function (en) {
              if (!en.isIntersecting) { return; }
              Object.keys(links).forEach(function (k) {
                links[k].removeAttribute("aria-current");
                links[k].classList.remove("is-selected");
              });
              var a = links[en.target.getAttribute("data-section-id")];
              if (a) { a.setAttribute("aria-current", "true"); a.classList.add("is-selected"); }
            });
          }, { rootMargin: "0px 0px -60% 0px" });
          for (var j = 0; j < secs.length; j++) { io.observe(secs[j]); }
        }
        var first = host.querySelector("a");
        if (first && !host.querySelector(".is-selected")) { first.setAttribute("aria-current", "true"); first.classList.add("is-selected"); }
      }
      host.__w42build = build;
      build();
      if (window.MutationObserver) {
        new MutationObserver(function (muts) {
          for (var m = 0; m < muts.length; m++) {
            for (var k = 0; k < muts[m].addedNodes.length; k++) {
              var n = muts[m].addedNodes[k];
              if (n.nodeType === 1 && n.localName === "w42-section") { setTimeout(build, 0); return; }
            }
          }
        }).observe(document.body, { childList: true, subtree: true });
      }
    }
  });

  /* — <w42-ac-list><w42-ac id="AC1">WHEN … THE SYSTEM SHALL …</w42-ac></w42-ac-list> — */
  define("w42-ac-list", {
    render: function (host) { addClass(host, "w42-ac-list"); host.setAttribute("role", "list"); }
  });
  var EARS = /\b(THE SYSTEM SHALL|WHEN|WHILE|IF|THEN|WHERE)\b/;
  function wrapEars(node) {
    var kids = Array.prototype.slice.call(node.childNodes);
    kids.forEach(function (k) {
      if (k.nodeType === 3) {
        if (!EARS.test(k.nodeValue)) { return; }
        var frag = document.createDocumentFragment();
        k.nodeValue.split(new RegExp(EARS.source, "g")).forEach(function (part, i) {
          if (i % 2 === 1) { frag.appendChild(el("span", "w42-ears", part)); }
          else if (part) { frag.appendChild(document.createTextNode(part)); }
        });
        node.replaceChild(frag, k);
      } else if (k.nodeType === 1 && !k.classList.contains("w42-ears")) { wrapEars(k); }
    });
  }
  define("w42-ac", {
    render: function (host) {
      addClass(host, "w42-ac");
      host.setAttribute("role", "listitem");
      var id = attr(host, "id", "");
      if (id) { host.setAttribute("data-ac-id", id); }
      var p = host.parentElement;
      if (p && !p.classList.contains("w42-ac-list")) {
        var list = el("div", "w42-ac-list");
        list.setAttribute("role", "list");
        p.insertBefore(list, host);
        var n = host;
        while (n && n.localName === "w42-ac") { var next = n.nextElementSibling; list.appendChild(n); n = next; }
      }
      var body = el("div", "w42-ac-body");
      while (host.firstChild) { body.appendChild(host.firstChild); }
      wrapEars(body);
      host.appendChild(body);
    }
  });

  /* — <w42-capsule label="Comment" size="sm|md|lg"> the 42 mark in a liquid-glass capsule — */
  define("w42-capsule", {
    render: function (host) {
      var label = attr(host, "label", "");
      var size = enumAttr("w42-capsule", host, "size", ["sm", "md", "lg"], "md");
      host.textContent = "";
      addClass(host, "w42-capsule");
      if (size !== "md") { addClass(host, "w42-capsule-" + size); }
      host.appendChild(el("span", "w42-capsule-mark"));
      if (label) { host.appendChild(el("span", "w42-capsule-label", label)); }
      host.setAttribute("role", "button");
      host.setAttribute("tabindex", "0");
      if (label) { host.setAttribute("aria-label", label); }
      keyActivate(host);
    }
  });

  /* ── Soft selection ──────────────────────────────────────────────────
     Native selection is hidden (CSS, once .w42-soft-selection is set) and a
     rounded, per-line merged highlight is painted that glides between
     selections. Skipped for selections inside form fields. */
  function installSoftSelection() {
    if (window.__w42SoftSelection || !document.body) { return; }
    window.__w42SoftSelection = true;
    var layer = el("div");
    layer.id = "w42-sel";
    document.body.appendChild(layer);
    var pool = [];
    function merged(range) {
      var out = [];
      Array.prototype.slice.call(range.getClientRects()).forEach(function (r) {
        if (r.width <= 1 || r.height <= 1) { return; }
        var last = out[out.length - 1];
        if (last && Math.abs(last.top - r.top) < 3 && r.left <= last.left + last.width + 2) {
          last.width = Math.max(last.width, r.left + r.width - last.left);
        } else { out.push({ left: r.left, top: r.top, width: r.width, height: r.height }); }
      });
      return out;
    }
    function paint(rects) {
      while (pool.length < rects.length) { var n = el("i"); layer.appendChild(n); pool.push(n); }
      pool.forEach(function (n, k) {
        var r = rects[k];
        if (!r) { n.classList.remove("on"); return; }
        n.style.left = (r.left - 3) + "px";
        n.style.top = (r.top - 1) + "px";
        n.style.width = (r.width + 6) + "px";
        n.style.height = (r.height + 2) + "px";
        n.classList.add("on");
      });
    }
    function update() {
      var sel = window.getSelection ? window.getSelection() : null;
      var active = document.activeElement;
      var inField = active && (active.localName === "input" || active.localName === "textarea");
      if (!sel || sel.rangeCount === 0 || sel.isCollapsed || inField) { paint([]); return; }
      paint(merged(sel.getRangeAt(0)));
    }
    document.addEventListener("selectionchange", update);
    window.addEventListener("scroll", update, true);
    window.addEventListener("resize", update);
    document.documentElement.classList.add("w42-soft-selection");
  }

  /* ── Spacing ─────────────────────────────────────────────────────── */

  var GAPS = /^s(4|8|12|16|20|24|32|40)$/;
  function gapOf(host, fallback) {
    var g = attr(host, "gap", "");
    if (!g) { return fallback; }
    if (!GAPS.test(g)) { throw new Error("gap must be one of s4, s8, s12, s16, s20, s24, s32, s40 (got \"" + g + "\")"); }
    return "var(--w42-" + g + ")";
  }

  /* — <w42-stack gap="s12"> vertical flow; <w42-cluster gap="s8" align="start|center|end|between"> wrapping row — */
  define("w42-stack", {
    render: function (host) {
      addClass(host, "w42-stack");
      var g = gapOf(host, "");
      if (g) { host.style.gap = g; }
    }
  });
  define("w42-cluster", {
    render: function (host) {
      addClass(host, "w42-cluster");
      var g = gapOf(host, "");
      if (g) { host.style.gap = g; }
      var a = attr(host, "align", "");
      if (a) {
        if (["start", "center", "end", "between"].indexOf(a) < 0) { throw new Error("align must be start, center, end or between"); }
        addClass(host, "w42-cluster-" + a);
      }
    }
  });

  // Adjacent inline controls (buttons, chips, spinners) in a block container are
  // wrapped in a .w42-cluster so they get a token gap without the author asking.
  var INLINE_KIT = { "w42-button": 1, "w42-chip": 1, "w42-spinner": 1, "w42-loading": 1, "button": 1 };
  var CLUSTER_PARENTS = { "div": 1, "section": 1, "main": 1, "article": 1, "form": 1, "fieldset": 1,
                          "w42-card": 1, "w42-group": 1, "w42-popover": 1 };
  function isInlineKit(n) {
    return n.nodeType === 1 && INLINE_KIT[n.localName] === 1 && !n.classList.contains("w42-tab");
  }
  function clusterRuns(root) {
    var parents = root.querySelectorAll ? root.querySelectorAll("*") : [];
    var list = [root].concat(Array.prototype.slice.call(parents));
    list.forEach(function (p) {
      if (p.nodeType !== 1 || CLUSTER_PARENTS[p.localName] !== 1) { return; }
      if (/\bw42-(cluster|row|stack|columns|grid|toolbar|tabs|segmented|dialog|popover-actions|hero-extra|hero-eyebrow|component|diagram|mockup|loader|toast|menu)/.test(p.className || "")) { return; }
      var disp = window.getComputedStyle ? window.getComputedStyle(p).display : "";
      if (disp.indexOf("flex") >= 0 || disp.indexOf("grid") >= 0) { return; }
      var run = [];
      function flush(before) {
        if (run.length >= 2) {
          var c = el("div", "w42-cluster");
          c.setAttribute("data-w42-auto", "");
          p.insertBefore(c, run[0]);
          run.forEach(function (n) { c.appendChild(n); });
        }
        run = [];
      }
      Array.prototype.slice.call(p.childNodes).forEach(function (n) {
        if (n.nodeType === 3 && !n.nodeValue.trim()) { return; }
        if (n.nodeType === 8) { return; }
        if (isInlineKit(n)) { run.push(n); } else { flush(); }
      });
      flush();
    });
  }
  var layoutTimer = null;
  function layout() {
    clearTimeout(layoutTimer);
    layoutTimer = setTimeout(function () { try { clusterRuns(document.body); } catch (e) { fail("layout", e); } }, 0);
  }

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
    layout();
    try { installSoftSelection(); } catch (e) { fail("selection", e); }
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
        layout();
      });
    }).observe(document.documentElement, { childList: true, subtree: true });
  }

  window.__w42 = window.__w42 || {};
  window.__w42.components = { define: define, registry: registry, legacy: LEGACY };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", watch);
  } else { watch(); }
})();

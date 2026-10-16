/* ============================================================
   Work42 kit diagram bridge.

   Every rendered diagram (mermaid output, inside `<w42-diagram>` or a bare
   `<pre class="mermaid">`) is wrapped in a card (`.wk-dcard`, styled by
   w42-widgets.css): a header with an icon tile, the title, a zoom readout and glass
   buttons — zoom out, zoom in, fit, copy, expand — over a pannable body.
   Zoom, fit and pan run in the page; Expand posts `{type:"expand", id}` to the
   `w42Diagram` message handler so the app opens the native dialog, which then asks
   `__w42Diagram.svg(id)` for the SVG. The dialog loads this same file.

   Optional attributes on <w42-diagram>: title="…", subtitle="…".
   ============================================================ */
(function () {
  "use strict";
  if (window.__w42DiagramBridgeInstalled) { return; }
  window.__w42DiagramBridgeInstalled = true;

  function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }

  var HANDLER = "w42Diagram";
  // Svgs inside a known diagram container. The interception is universal: a
  // document never opts in.
  var DIAGRAM_SELECTOR = ".mermaid, pre.mermaid, code.language-mermaid, w42-diagram";
  var MIN_CARD_WIDTH = 340; // room for the title and five header controls
  var seq = 0;
  var reg = {}; // id -> { svg, slot, card, base, cur, ar, minw, maxw, zoomEl }

  function post(msg) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[HANDLER]) {
        window.webkit.messageHandlers[HANDLER].postMessage(msg);
      }
    } catch (e) { /* no native host (plain browser) */ }
  }

  // An SF Symbol, drawn by the app (`_w42/sf/<name>.png`, or `window.__w42SfBase` when a host serves
  // them elsewhere, e.g. a markdown document) and tinted by currentColor.
  function sf(name) {
    var s = document.createElement("span");
    s.className = "w42-sf";
    s.style.setProperty("--sf", 'url("' + (window.__w42SfBase || "_w42/sf/") + name + '.png")');
    s.setAttribute("aria-hidden", "true");
    return s;
  }

  function isDiagram(svg) {
    if (svg.__w42Diagram) { return false; }
    if (svg.closest(".wk-dhead")) { return false; }
    var id = svg.getAttribute("id") || "";
    if (id.indexOf("mermaid") === 0) { return true; }
    if (svg.getAttribute("aria-roledescription")) { return true; }
    if (svg.closest(DIAGRAM_SELECTOR)) { return true; }
    var r = svg.getBoundingClientRect();
    return r.width >= 120 && r.height >= 80;
  }

  function applyVB(st) {
    if (!st.cur) { return; }
    st.svg.setAttribute("viewBox", st.cur.x + " " + st.cur.y + " " + st.cur.w + " " + st.cur.h);
    if (st.zoomEl && st.base) { st.zoomEl.textContent = Math.round(st.base.w / st.cur.w * 100) + "%"; }
  }
  function clampPan(st) {
    var mx = st.cur.w * 0.5, my = st.cur.h * 0.5;
    st.cur.x = clamp(st.cur.x, st.base.x - mx, st.base.x + st.base.w - st.cur.w + mx);
    st.cur.y = clamp(st.cur.y, st.base.y - my, st.base.y + st.base.h - st.cur.h + my);
  }

  // Size the card from the diagram's tight content bounds: it hugs the graph's
  // natural width and shrinks to fit the column (max-width 100%, height auto).
  function sizeCard(st) {
    if (!st.base) { return false; }
    st.card.style.width = Math.max(MIN_CARD_WIDTH, Math.ceil(st.base.w)) + "px";
    st.card.style.maxWidth = "100%";
    st.card.classList.add("is-sized");
    st.svg.style.display = "block";
    st.svg.style.width = "100%";
    st.svg.style.height = "auto";
    st.svg.style.maxWidth = "none";
    st.svg.removeAttribute("width");
    st.svg.removeAttribute("height");
    return true;
  }

  // Capture the base viewBox (tight getBBox bounds, the SVG viewBox as fallback).
  // May fail while the diagram is still laying out: retried on every scan and every gesture.
  function captureBase(st) {
    if (st.base) { return true; }
    var bb = null;
    try { bb = st.svg.getBBox(); } catch (e) {}
    var base = null;
    if (bb && bb.width > 1 && bb.height > 1) {
      base = { x: bb.x, y: bb.y, w: bb.width, h: bb.height };
    } else {
      var vb = st.svg.viewBox && st.svg.viewBox.baseVal;
      if (vb && vb.width && vb.height) { base = { x: vb.x, y: vb.y, w: vb.width, h: vb.height }; }
    }
    if (!base) { return false; }
    var pad = 0.03;
    base = { x: base.x - base.w * pad, y: base.y - base.h * pad, w: base.w * (1 + 2 * pad), h: base.h * (1 + 2 * pad) };
    st.base = base;
    st.cur = { x: base.x, y: base.y, w: base.w, h: base.h };
    st.ar = base.h / base.w;
    st.minw = base.w / 16;
    st.maxw = base.w;
    applyVB(st);
    sizeCard(st);
    return true;
  }

  // Wrap the svg in a card we control, once: header + pannable body.
  function cardFor(svg) {
    var existing = svg.closest(".wk-dcard");
    if (existing) {
      return { card: existing, header: existing.querySelector(".wk-dhead"), slot: existing.querySelector(".wk-dslot") };
    }
    var parent = svg.parentNode;
    if (!parent) { return null; }
    var card = document.createElement("div");
    card.className = "wk-dcard is-diagram";
    var header = document.createElement("div");
    header.className = "wk-dhead";
    var slot = document.createElement("div");
    slot.className = "wk-dbody wk-dslot";
    parent.insertBefore(card, svg);
    card.appendChild(header);
    card.appendChild(slot);
    slot.appendChild(svg);
    return { card: card, header: header, slot: slot };
  }

  function titleFor(svg) {
    var host = svg.closest("w42-diagram[title], [data-w42-title]");
    if (host) { return host.getAttribute("title") || host.getAttribute("data-w42-title") || "Diagram"; }
    var t = svg.querySelector("title");
    if (t && t.textContent && t.textContent.trim()) { return t.textContent.trim(); }
    return "Diagram";
  }
  function subtitleFor(svg) {
    var host = svg.closest("w42-diagram[subtitle]");
    return host ? host.getAttribute("subtitle") : "";
  }

  function prep(svg) {
    svg.__w42Diagram = true;
    var parts = cardFor(svg);
    if (!parts) { return; }
    var id = "w42d-" + (++seq);
    parts.card.setAttribute("data-w42-diagram-id", id);
    svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
    var st = {
      id: id, svg: svg, card: parts.card, header: parts.header, slot: parts.slot,
      title: titleFor(svg), subtitle: subtitleFor(svg), base: null, cur: null, zoomEl: null
    };
    reg[id] = st;
    buildHeader(st);
    captureBase(st);
    attachGestures(st);
  }

  function glassButton(label, symbol, fn, cls) {
    var b = document.createElement("button");
    b.type = "button";
    b.className = cls || "";
    b.title = label;
    b.setAttribute("aria-label", label);
    b.appendChild(sf(symbol));
    b.addEventListener("click", function (e) { e.preventDefault(); e.stopPropagation(); fn(b); });
    return b;
  }

  // Copy the diagram's SVG source to the clipboard, confirming with a check.
  function copySVG(st, btn) {
    var text = st.svg.outerHTML;
    function done() {
      var icon = btn.firstChild;
      btn.replaceChild(sf("checkmark"), icon);
      setTimeout(function () { btn.replaceChild(icon, btn.firstChild); }, 1200);
    }
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text); done(); });
        return;
      }
    } catch (e) {}
    fallbackCopy(text); done();
  }
  function fallbackCopy(text) {
    var ta = document.createElement("textarea");
    ta.value = text; ta.setAttribute("readonly", ""); ta.style.position = "fixed"; ta.style.opacity = "0";
    document.body.appendChild(ta); ta.select();
    try { document.execCommand("copy"); } catch (e) {}
    document.body.removeChild(ta);
  }

  function buildHeader(st) {
    var h = st.header;
    h.textContent = "";
    var tile = document.createElement("span");
    tile.className = "wk-dicon";
    tile.appendChild(sf("point.3.connected.trianglepath.dotted"));
    var text = document.createElement("div");
    text.className = "wk-dtext";
    var title = document.createElement("div");
    title.className = "wk-dtitle";
    title.textContent = st.title;
    text.appendChild(title);
    if (st.subtitle) {
      var sub = document.createElement("div");
      sub.className = "wk-dsub";
      sub.textContent = st.subtitle;
      text.appendChild(sub);
    }
    var zoom = document.createElement("span");
    zoom.className = "wk-dzoom";
    zoom.textContent = "100%";
    st.zoomEl = zoom;

    var actions = document.createElement("div");
    actions.className = "wk-dactions";
    var group = document.createElement("span");
    group.className = "wk-group";
    group.appendChild(glassButton("Zoom out", "minus.magnifyingglass", function () { doZoom(st, 1.3, 0.5, 0.5); }));
    group.appendChild(glassButton("Zoom in", "plus.magnifyingglass", function () { doZoom(st, 1 / 1.3, 0.5, 0.5); }));
    group.appendChild(glassButton("Fit to view", "arrow.up.left.and.arrow.down.right", function () { doReset(st); }));
    actions.appendChild(group);
    actions.appendChild(glassButton("Copy SVG", "doc.on.doc", function (b) { copySVG(st, b); }, "wk-btn wk-btn-icon wk-btn-sm"));
    actions.appendChild(glassButton("Expand", "arrow.up.backward.and.arrow.down.forward", function () { post({ type: "expand", id: st.id }); }, "wk-btn wk-btn-icon wk-btn-sm"));
    h.appendChild(tile);
    h.appendChild(text);
    h.appendChild(zoom);
    h.appendChild(actions);
  }

  // Shared viewBox math (header buttons, gestures and the native dialog). `fx`/`fy` are
  // the 0..1 focal point; `dxFrac`/`dyFrac` pan deltas as a fraction of the current view.
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

  // In-page gestures: ctrl/cmd+scroll or pinch zooms at the cursor, two-finger scroll
  // pans when zoomed, drag pans, double-click fits.
  function attachGestures(st) {
    var slot = st.slot;
    slot.addEventListener("wheel", function (e) {
      if (!captureBase(st)) { return; }
      if (e.ctrlKey || e.metaKey) {
        e.preventDefault();
        var r = st.svg.getBoundingClientRect();
        doZoom(st, Math.exp(e.deltaY * 0.01), (e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height);
      } else if (isZoomed(st)) {
        e.preventDefault();
        var r2 = st.svg.getBoundingClientRect();
        doPan(st, e.deltaX / r2.width, e.deltaY / r2.height);
      }
    }, { passive: false });
    var drag = false, lx = 0, ly = 0;
    slot.addEventListener("mousedown", function (e) {
      if (!captureBase(st)) { return; }
      drag = true; lx = e.clientX; ly = e.clientY; e.preventDefault();
    });
    window.addEventListener("mousemove", function (e) {
      if (!drag) { return; }
      var r = st.svg.getBoundingClientRect();
      doPan(st, -(e.clientX - lx) / r.width, -(e.clientY - ly) / r.height);
      lx = e.clientX; ly = e.clientY;
    });
    window.addEventListener("mouseup", function () { drag = false; });
    slot.addEventListener("dblclick", function (e) { e.preventDefault(); doReset(st); });
  }

  function each(fn) { for (var id in reg) { if (reg.hasOwnProperty(id)) { fn(reg[id]); } } }

  // In-page API driven by the header buttons, and by the native expand dialog's header.
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
    for (var j = 0; j < list.length; j++) { if (isDiagram(list[j])) { prep(list[j]); } }
    // Mermaid can expose the svg before getBBox has usable bounds: retry unsized diagrams.
    each(function (st) { if (!st.base) { captureBase(st); } });
  }

  // Poll long enough to catch late-rendering mermaid, then stop (bounded; no MutationObserver).
  var ticks = 0;
  function tick() { scan(); if (++ticks < 40) { setTimeout(tick, 500); } }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", tick);
  } else {
    tick();
  }
})();

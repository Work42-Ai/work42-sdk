/* ============================================================
   Work42 kit runtime: the device mockup, toasts and the 42 loader.
   (The diagram card is w42-diagram.js.)

   <w42-mockup title="…" url="https://…" device="iphone-16-pro|iphone-15|pixel-7|ipad-11|web">
   <w42-flutter-mockup title="…" app="path/to/flutter/app" device="…">
   w42Toast("Saved", { tone: "success|danger|warning|info", duration: 4000 })
   <pre data-title="…"><code class="language-x"> → a code card (tile, title, language badge, copy)

   Markup is built from the kit recipes (wk-*, styled by w42-recipes.css and
   w42-widgets.css) and SF Symbols (`w42-sf`), so it follows the app's tokens,
   light/dark and accent.
   ============================================================ */
(function () {
  "use strict";
  if (window.__w42KitInstalled) { return; }
  window.__w42KitInstalled = true;

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) { n.className = cls; }
    if (text != null) { n.textContent = text; }
    return n;
  }
  // A relative URL inside a custom property resolves against the stylesheet that uses it (`_w42/kit/`),
  // not the page, so `_w42/sf/` would become `_w42/kit/_w42/sf/` and 404. Resolve against the page.
  function sfURL(name) {
    // An exported page has no _w42/sf/ to fetch from: the exporter hands over the icons as data URIs.
    var inlined = window.__w42SfData && window.__w42SfData[name];
    if (inlined) { return inlined; }
    return new URL((window.__w42SfBase || "_w42/sf/") + name + ".png", document.baseURI).href;
  }
  // An SF Symbol, drawn by the app (`_w42/sf/<name>.png`, or `window.__w42SfBase` when a host serves
  // them elsewhere, e.g. a markdown document) and tinted by currentColor.
  function sf(name) {
    var s = el("span", "w42-sf");
    s.style.setProperty("--sf", 'url("' + sfURL(name) + '")');
    s.setAttribute("aria-hidden", "true");
    return s;
  }
  function attr(node, name, fallback) {
    var v = node.getAttribute(name);
    return v == null || v === "" ? fallback : v;
  }
  function replace(node, next) { if (node.parentNode) { node.parentNode.replaceChild(next, node); } }

  window.__w42 = window.__w42 || {};

  // ---- Error card: the failure is shown AND reported (console.error reaches the error overlay,
  // which writes errors.jsonl, so `work42 artifact status` catches a broken widget mechanically) ----
  function errorCard(title, message) {
    var card = el("div", "wk-dcard is-error");
    var head = el("div", "wk-dhead");
    var tile = el("span", "wk-dicon is-danger");
    tile.appendChild(sf("exclamationmark.triangle"));
    var text = el("div", "wk-dtext");
    text.appendChild(el("div", "wk-dtitle", title || "Error"));
    head.appendChild(tile); head.appendChild(text);
    var body = el("div", "wk-dbody", message);
    card.appendChild(head); card.appendChild(body);
    if (window.console && console.error) {
      console.error("w42 component error [" + (title || "component") + "]: " + message);
    }
    return card;
  }

  // ---- The 42 brand loader ----
  var LOADER42_SVG = '<svg class="wk-loader42" viewBox="0 0 256 256" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Loading"><defs><mask id="w42om" maskUnits="userSpaceOnUse" x="0" y="0" width="135" height="256"><path d="M140 77 L104 77 Q90 77 80.4 87.1 L16 155" pathLength="1" fill="none" stroke="#fff" stroke-width="40" stroke-linecap="butt" stroke-linejoin="round" stroke-dasharray="0 0 0 1"><animate attributeName="stroke-dasharray" dur="3.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.0405;0.5;0.5405;1" values="0 0 0 1 ; 0 0 1 0 ; 0 0 1 0 ; 0 1 0 0 ; 0 1 0 0" keySplines="0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0"/></path><path d="M7 153 L126 153" pathLength="1" fill="none" stroke="#fff" stroke-width="26" stroke-linecap="butt" stroke-linejoin="round" stroke-dasharray="0 0 0 1"><animate attributeName="stroke-dasharray" dur="3.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.0405;0.0874;0.5405;0.5874;1" values="0 0 0 1 ; 0 0 0 1 ; 0 0 1 0 ; 0 0 1 0 ; 0 1 0 0 ; 0 1 0 0" keySplines="0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0"/></path><path d="M111 153 L111 188" pathLength="1" fill="none" stroke="#fff" stroke-width="30" stroke-linecap="butt" stroke-linejoin="round" stroke-dasharray="0 0 0 1"><animate attributeName="stroke-dasharray" dur="3.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.0874;0.1049;0.5874;0.6049;1" values="0 0 0 1 ; 0 0 0 1 ; 0 0 1 0 ; 0 0 1 0 ; 0 1 0 0 ; 0 1 0 0" keySplines="0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0"/></path><g clip-path="url(#olean)"><path d="M100 142 L122 96" pathLength="1" fill="none" stroke="#fff" stroke-width="52" stroke-linecap="butt" stroke-linejoin="round" stroke-dasharray="0 0 0 1"><animate attributeName="stroke-dasharray" dur="3.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.1246;0.1589;0.6246;0.6589;1" values="0 0 0 1 ; 0 0 0 1 ; 0 0 1 0 ; 0 0 1 0 ; 0 1 0 0 ; 0 1 0 0" keySplines="0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0"/></path></g></mask><mask id="w42vm" maskUnits="userSpaceOnUse" x="133" y="0" width="123" height="256"><path d="M133 115 L219 115 C236 115 236 77 219 77 L128 77" pathLength="1" fill="none" stroke="#fff" stroke-width="46" stroke-linecap="butt" stroke-linejoin="round" stroke-dasharray="0 0 0 1"><animate attributeName="stroke-dasharray" dur="3.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.1589;0.5;0.6589;1" values="0 0 0 1 ; 0 0 0 1 ; 0 0 1 0 ; 0 0 1 0 ; 0 1 0 0" keySplines="0.0 0.0 1.0 1.0 ; 0.29 0.514 0.645 0.73 ; 0.0 0.0 1.0 1.0 ; 0.29 0.514 0.645 0.73"/></path><path d="M133 152 L254 152" pathLength="1" fill="none" stroke="#fff" stroke-width="46" stroke-linecap="butt" stroke-linejoin="round" stroke-dasharray="0 0 0 1"><animate attributeName="stroke-dasharray" dur="3.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.1589;0.2444;0.6589;0.7444;1" values="0 0 0 1 ; 0 0 0 1 ; 0 0 1 0 ; 0 0 1 0 ; 0 1 0 0 ; 0 1 0 0" keySplines="0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0 ; 0.0 0.0 1.0 1.0"/></path></mask><clipPath id="olean"><rect x="0" y="96" width="135" height="46"/></clipPath></defs><path class="wk-l42-shade" d="M50 140 L96 140 L96 128 L80 128 L103 103 L135 103 L135 128 L126 128 L126 188 L96 188 L96 166 L8 166 L7 141 L16 134 L80 64 L135 64 L135 90 L100 90 Z"/><path class="wk-l42-shade" d="M134 64 L222 64 C238 64 249 71 249 87 L249 107 C249 121 240 128 228 128 L134 128 L134 103 L213 103 Q218 103 218 98.5 L218 94.5 Q218 90 213 90 L134 90 Z"/><path class="wk-l42-shade" d="M135 139 L249 139 L249 166 L135 166 Z"/><path class="wk-l42-o wk-l42-mask" d="M50 140 L96 140 L96 128 L80 128 L103 103 L135 103 L135 128 L126 128 L126 188 L96 188 L96 166 L8 166 L7 141 L16 134 L80 64 L135 64 L135 90 L100 90 Z" mask="url(#w42om)"/><g class="wk-l42-mask" mask="url(#w42vm)"><path class="wk-l42-v" d="M134 64 L222 64 C238 64 249 71 249 87 L249 107 C249 121 240 128 228 128 L134 128 L134 103 L213 103 Q218 103 218 98.5 L218 94.5 Q218 90 213 90 L134 90 Z"/><path class="wk-l42-v" d="M135 139 L249 139 L249 166 L135 166 Z"/></g></svg>';
  function buildLoader(msg) {
    var box = el("div", "wk-loader");
    var mark = el("div", "wk-loader-mark");
    mark.innerHTML = LOADER42_SVG;
    box.appendChild(mark);
    box.appendChild(el("div", "wk-loader-text", msg || ""));
    return box;
  }
  window.__w42.buildLoader = buildLoader;

  // ---- Toasts ----
  var TOAST_ICON = { success: "checkmark", danger: "xmark", warning: "exclamationmark", info: "info" };
  window.w42Toast = function (message, opts) {
    opts = opts || {};
    var tone = TOAST_ICON[opts.tone] ? opts.tone : "info";
    var region = document.getElementById("wk-toaster");
    if (!region) {
      region = el("div");
      region.id = "wk-toaster";
      region.setAttribute("role", "status");
      region.setAttribute("aria-live", "polite");
      document.body.appendChild(region);
    }
    var toast = el("div", "wk-toast wk-material" + (tone === "info" ? "" : " is-" + tone));
    var ico = el("span", "wk-toast-ico");
    ico.appendChild(sf(TOAST_ICON[tone]));
    var text = el("div", "wk-toast-text", String(message));
    toast.appendChild(ico); toast.appendChild(text);
    region.appendChild(toast);
    function dismiss() { if (toast.parentNode) { toast.parentNode.removeChild(toast); } }
    setTimeout(dismiss, opts.duration || 4000);
    toast.addEventListener("click", dismiss);
    return toast;
  };

  // ---- Device mockup ----
  var fmSeq = 0;
  // insetTop/insetBottom (device px, scaled with the frame) reserve the real safe areas
  // (status bar, home indicator) so the embedded app sits INSIDE the screen like on a device.
  var DEVICES = {
    "iphone-16-pro": { w: 402, h: 874,  radius: 55, chrome: "island", platform: "ios",     insetTop: 54, insetBottom: 34 },
    "iphone-15":     { w: 393, h: 852,  radius: 52, chrome: "island", platform: "ios",     insetTop: 50, insetBottom: 34 },
    "pixel-7":       { w: 412, h: 915,  radius: 30, chrome: "punch",  platform: "android", insetTop: 32, insetBottom: 24 },
    "ipad-11":       { w: 834, h: 1194, radius: 22, chrome: "none",   platform: "ipados",  insetTop: 24, insetBottom: 20 },
    "web":           { w: 1280, h: 800, radius: 8,  chrome: "none",   platform: "web",     insetTop: 0,  insetBottom: 0 }
  };
  // The segmented picker: segment -> device key (iPhone keeps an `iphone-15` the author asked for).
  var SEGMENTS = [
    { id: "iphone",  label: "iPhone",  symbol: "iphone",         platform: "ios" },
    { id: "android", label: "Android", symbol: "candybarphone",  platform: "android" },
    { id: "ipad",    label: "iPad",    symbol: "ipad",           platform: "ipados" },
    { id: "web",     label: "Web",     symbol: "globe",          platform: "web" }
  ];
  var SB_SIGNAL  = '<svg viewBox="0 0 18 12" fill="#fff"><rect x="0" y="8" width="3" height="4" rx="0.7"/><rect x="5" y="5.5" width="3" height="6.5" rx="0.7"/><rect x="10" y="3" width="3" height="9" rx="0.7"/><rect x="15" y="0.5" width="3" height="11.5" rx="0.7"/></svg>';
  var SB_WIFI    = '<svg viewBox="0 0 16 12" fill="#fff"><path d="M8 11.2 5.9 8.6a3.3 3.3 0 0 1 4.2 0L8 11.2zM3.7 5.9 2 3.8a9.3 9.3 0 0 1 12 0l-1.7 2.1a6.6 6.6 0 0 0-8.6 0z"/></svg>';
  var SB_BATTERY = '<svg viewBox="0 0 26 12" fill="none"><rect x="0.6" y="0.6" width="21" height="10.8" rx="2.6" stroke="#fff" stroke-opacity="0.55" stroke-width="1"/><rect x="2.2" y="2.2" width="17" height="7.6" rx="1.4" fill="#fff"/><path d="M23.4 4.2v3.6a2 2 0 0 0 0-3.6z" fill="#fff" fill-opacity="0.55"/></svg>';
  var FLUTTER_ICON = '<svg viewBox="0 0 24 24" fill="#54C5F8"><path d="M14.314 0L2.3 12 6 15.7 21.684.013h-7.357zm.014 11.072L7.857 17.53l6.47 6.47H21.7l-6.46-6.468 6.46-6.46h-7.37z"/></svg>';

  var FM_HANDLER = "w42FlutterMockup";
  function fmPost(msg) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[FM_HANDLER]) {
        window.webkit.messageHandlers[FM_HANDLER].postMessage(msg);
      }
    } catch (e) {}
  }
  // Per-mockup callback registry + the native-to-page API. Native resolves `app` to a
  // served Flutter-web URL and calls ready(id, url).
  window.__w42FM = window.__w42FM || { _cbs: {} };
  window.__w42FlutterMockup = {
    ready: function (id, url) { var c = window.__w42FM._cbs[id]; if (c && c.ready) { c.ready(url); } },
    error: function (id, msg) { var c = window.__w42FM._cbs[id]; if (c && c.error) { c.error(msg); } },
    reload: function (id) { var c = window.__w42FM._cbs[id]; if (c && c.reload) { c.reload(); } }
  };

  function segmented(items, onSelect) {
    var seg = el("div", "wk-seg is-sm");
    var buttons = [];
    items.forEach(function (item, i) {
      var b = el("button");
      b.type = "button";
      b.title = item.title || item.label || "";
      b.setAttribute("aria-label", item.title || item.label || "");
      b.appendChild(sf(item.symbol));
      if (item.label) { b.appendChild(document.createTextNode(item.label)); }
      b.addEventListener("click", function () { select(i); onSelect(item, i); });
      seg.appendChild(b);
      buttons.push(b);
    });
    function select(index) {
      buttons.forEach(function (b, k) { b.setAttribute("aria-pressed", k === index ? "true" : "false"); });
    }
    return { node: seg, select: select };
  }

  function upgradeMockup(node) {
    var title = attr(node, "title", "Mockup");
    var url = attr(node, "url", "");
    var app = attr(node, "app", "");
    var deviceKey = attr(node, "device", "iphone-16-pro");
    if (!DEVICES[deviceKey]) { deviceKey = "iphone-16-pro"; }
    var id = "w42fm-" + (++fmSeq);
    var currentKey = deviceKey;

    var scaler = el("div", "wk-mk-scaler");
    var frame = el("div", "wk-mk-frame");
    var statusbar = el("div", "wk-mk-statusbar");
    statusbar.innerHTML = '<div class="wk-mk-sb-time">9:41</div><div class="wk-mk-sb-icons">' + SB_SIGNAL + SB_WIFI + SB_BATTERY + '</div>';
    var screen = el("div", "wk-mk-screen");
    var iframe = document.createElement("iframe");
    iframe.className = "wk-mk-iframe";
    iframe.setAttribute("frameborder", "0");
    iframe.setAttribute("sandbox", "allow-scripts allow-same-origin allow-forms allow-popups allow-modals");
    screen.appendChild(iframe);
    var home = el("div", "wk-mk-home");
    home.appendChild(el("div", "wk-mk-home-bar"));
    var chrome = el("div", "wk-mk-chrome"); // Dynamic Island / punch-hole
    frame.appendChild(statusbar); frame.appendChild(screen); frame.appendChild(home); frame.appendChild(chrome);
    scaler.appendChild(frame);
    var status = el("div", "wk-mk-status");
    status.style.display = "none";
    var loading = el("div", "wk-mk-loading");
    loading.appendChild(buildLoader(""));
    loading.style.display = "none";
    var stage = el("div", "wk-mk-stage");
    stage.appendChild(scaler); stage.appendChild(loading); stage.appendChild(status);

    // Card: header (icon tile, title + source, pickers) over the stage.
    var card = el("div", "wk-dcard");
    var head = el("div", "wk-dhead");
    var tile = el("span", "wk-dicon" + (app ? "" : " is-success"));
    if (app) { tile.innerHTML = FLUTTER_ICON; tile.style.width = "28px"; tile.firstChild.style.width = "16px"; }
    else { tile.appendChild(sf("eye")); }
    var text = el("div", "wk-dtext");
    text.appendChild(el("div", "wk-dtitle", title));
    var source = url || app;
    if (source) { text.appendChild(el("div", "wk-dsub", source)); }
    var actions = el("div", "wk-dactions");

    var startSeg = 0;
    SEGMENTS.forEach(function (s, i) { if (s.platform === DEVICES[deviceKey].platform) { startSeg = i; } });
    var devicePicker = segmented(SEGMENTS, function (item) {
      currentKey = item.id === "iphone" ? (deviceKey.indexOf("iphone") === 0 ? deviceKey : "iphone-16-pro")
        : item.id === "android" ? "pixel-7" : item.id === "ipad" ? "ipad-11" : "web";
      sizeFrame();
      if (app && !url) { fmPost({ type: "device", id: id, device: currentKey }); }
    });
    devicePicker.select(startSeg);

    // Preview the embedded app in light / dark (themes the iframe, not the card).
    var schemes = [
      { id: "auto", symbol: "circle.lefthalf.filled", title: "App theme: automatic" },
      { id: "light", symbol: "sun.max", title: "App theme: light" },
      { id: "dark", symbol: "moon", title: "App theme: dark" }
    ];
    var schemePicker = segmented(schemes, function (item) {
      iframe.style.colorScheme = item.id === "auto" ? "normal" : item.id;
    });
    schemePicker.node.classList.add("is-icons");
    schemePicker.select(0);

    actions.appendChild(devicePicker.node);
    actions.appendChild(schemePicker.node);
    head.appendChild(tile); head.appendChild(text); head.appendChild(actions);
    var body = el("div", "wk-dbody");
    body.appendChild(stage);
    card.appendChild(head); card.appendChild(body);

    function sizeFrame() {
      var d = DEVICES[currentKey] || DEVICES[deviceKey];
      frame.style.width = d.w + "px";
      frame.style.height = d.h + "px";
      frame.style.borderRadius = (d.radius || 20) + "px";
      frame.className = "wk-mk-frame wk-mk-" + (d.platform || "web");
      chrome.className = "wk-mk-chrome wk-mk-chrome-" + (d.chrome || "none");
      statusbar.style.height = (d.insetTop || 0) + "px";
      home.style.height = (d.insetBottom || 0) + "px";
      statusbar.style.display = d.insetTop ? "flex" : "none";
      home.style.display = d.insetBottom ? "flex" : "none";
      var avail = (stage.clientWidth || body.clientWidth || 0) - 16;
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
      status.className = "wk-mk-status" + (isErr ? " is-error" : "");
      loading.style.display = "none";
    }
    function showLoading(msg) {
      var t = loading.querySelector(".wk-loader-text");
      if (t) { t.textContent = msg; }
      loading.style.display = "flex";
      status.style.display = "none";
    }
    window.addEventListener("resize", sizeFrame);

    replace(node, card);
    setTimeout(sizeFrame, 0);

    var started = false;
    function startBuild() {
      if (started) { return; }
      started = true;
      showLoading("Setting up your Flutter mockup\u2026");
      window.__w42FM._cbs[id] = {
        ready: function (u) { setURL(u); },
        error: function (m) { setStatus(m || "Build failed", true); },
        reload: function () { if (iframe.src) { var s = iframe.src; iframe.src = "about:blank"; iframe.src = s; } }
      };
      fmPost({ type: "start", id: id, app: app, device: currentKey });
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
        io.observe(card);
      } else {
        startBuild();
      }
    } else {
      setStatus("Set a url= or app= attribute", true);
    }
  }

  // ---- Code card: a plain <pre><code> becomes a card, so an author never styles a code block ----
  // Tile, title (the pre's data-title, else the language), a language badge when there is a title of
  // its own, a copy button and a padded body that scrolls sideways instead of clipping. A block that
  // is already inside a card (the author composed their own), a diagram, a document's prose, or is
  // Mermaid, is left alone. The pre node is moved, not cloned, so highlighting is kept.
  function codeLanguage(code) {
    var m = /(?:^|\s)(?:language|lang)-([\w+#-]+)/.exec(code.className || "");
    return m ? m[1] : "";
  }
  function copyCode(code, btn) {
    var text = code.textContent || "";
    function done() {
      var icon = btn.firstChild;
      btn.replaceChild(sf("checkmark"), icon);
      setTimeout(function () { btn.replaceChild(icon, btn.firstChild); }, 1200);
    }
    function fallback() {
      var ta = document.createElement("textarea");
      ta.value = text; ta.setAttribute("readonly", ""); ta.style.position = "fixed"; ta.style.opacity = "0";
      document.body.appendChild(ta); ta.select();
      try { document.execCommand("copy"); } catch (e) {}
      document.body.removeChild(ta);
      done();
    }
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, fallback);
        return;
      }
    } catch (e) {}
    fallback();
  }
  function upgradeCode(pre) {
    if (pre.__w42Code) { return; }
    pre.__w42Code = true;
    var code = pre.firstElementChild;
    if (!code || code.tagName !== "CODE" || pre.children.length !== 1) { return; }
    var lang = codeLanguage(code);
    if (lang === "mermaid" || pre.classList.contains("mermaid")) { return; }
    if (pre.closest(".wk-ccard, .wk-dcard, .wk-card, .w42-prose, w42-diagram, w42-mockup, w42-flutter-mockup")) { return; }
    var title = pre.getAttribute("data-title") || lang || "Code";

    var card = el("div", "wk-ccard");
    var head = el("div", "wk-chead");
    var tile = el("span", "wk-cicon");
    tile.appendChild(sf("terminal"));
    head.appendChild(tile);
    head.appendChild(el("div", "wk-ctitle", title));
    if (lang && pre.hasAttribute("data-title")) { head.appendChild(el("span", "wk-clang", lang)); }
    var btn = el("button", "wk-btn wk-btn-icon wk-btn-sm wk-ccopy");
    btn.type = "button";
    btn.title = "Copy code";
    btn.setAttribute("aria-label", "Copy code");
    btn.appendChild(sf("doc.on.doc"));
    btn.addEventListener("click", function (e) { e.preventDefault(); e.stopPropagation(); copyCode(code, btn); });
    head.appendChild(btn);

    pre.parentNode.insertBefore(card, pre);
    pre.classList.add("wk-cbody");
    card.appendChild(head);
    card.appendChild(pre);
  }
  function upgradeAllCode() {
    var codes = document.querySelectorAll("pre > code");
    for (var i = 0; i < codes.length; i++) { upgradeCode(codes[i].parentNode); }
  }
  window.__w42.upgradeCode = upgradeAllCode;
  if (document.readyState === "loading") { document.addEventListener("DOMContentLoaded", upgradeAllCode); }
  else { upgradeAllCode(); }

  function defineMockup(tag) {
    if (!window.customElements || window.customElements.get(tag)) { return; }
    window.customElements.define(tag, class extends HTMLElement {
      connectedCallback() {
        if (this.__w42Ready) { return; }
        this.__w42Ready = true;
        try { upgradeMockup(this); }
        catch (err) { replace(this, errorCard(tag, String((err && err.message) || err))); }
      }
    });
  }
  defineMockup("w42-mockup");
  defineMockup("w42-flutter-mockup");
})();

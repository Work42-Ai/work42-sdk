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
    var source = (node.textContent || "").replace(/^\n/, "").replace(/\s+$/, "");
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
      catch (e) { replace(node, errorCard(title, "w42-table: invalid data-rows JSON\n" + e.message)); return; }
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
      showLoading("Setting up your Flutter mockup\u2026");
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
  window.__w42.cards = {
    code: upgradeCode, table: upgradeTable, mockup: upgradeMockup,
    replace: replace, errorCard: errorCard
  };
})();

/* w42-components.js — the <w42-*> tag runtime.
 *
 * Each tag is a custom element that expands, in the light DOM, to the
 * `.w42-*` classes in w42-components.css. Tags are the agent-facing API; the
 * classes stay available underneath. The card tags (w42-code, w42-table,
 * w42-mockup, w42-flutter-mockup, w42-diagram) are registered here too, so
 * this file is the one registry; their card builders sit in the "shell cards"
 * block at the top, with the live theme bridge (window.__w42.theme).
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

  /* ── Card tags: w42-code, w42-table, w42-mockup, w42-flutter-mockup, w42-diagram ── */
  var cards = window.__w42.cards;
  function cardSpec(tag, fn) {
    return {
      render: function (host) {
        try { fn(host); }
        catch (err) {
          // errorCard() reports to the overlay sink (errors.jsonl) itself.
          try { cards.replace(host, cards.errorCard(tag, String((err && err.message) || err))); }
          catch (e2) { fail(tag, err); }
        }
      }
    };
  }
  define("w42-code", cardSpec("w42-code", cards.code));
  define("w42-table", cardSpec("w42-table", cards.table));
  define("w42-mockup", cardSpec("w42-mockup", cards.mockup));
  define("w42-flutter-mockup", cardSpec("w42-flutter-mockup", cards.mockup));
  /* — <w42-diagram><pre class="mermaid">…</pre></w42-diagram> — a block wrapper; the mermaid
       engine turns the <pre> inside into the zoom / reset / expand card. — */
  define("w42-diagram", {
    render: function (host) { addClass(host, "w42-diagram"); }
  });

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
      if (tag.indexOf("w42-") !== 0 || registry[tag]) { continue; }
      if (all[i].getAttribute("data-w42-unknown")) { continue; }
      all[i].setAttribute("data-w42-unknown", "1");
      fail(tag, "unknown component");
    }
  }

  function watch() {
    reportUnknown(document);
    layout();
    if (!window.MutationObserver) { return; }
    new MutationObserver(function (muts) {
      muts.forEach(function (m) {
        for (var i = 0; i < m.addedNodes.length; i++) {
          var n = m.addedNodes[i];
          if (n.nodeType !== 1) { continue; }
          if (n.localName.indexOf("w42-") === 0 && !registry[n.localName]) {
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
  window.__w42.components = { define: define, registry: registry };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", watch);
  } else { watch(); }
})();

# Changelog

## Unreleased

- Add `EnvironmentValues.widgetSessionServices`, set by the host around every plugin widget.
  `BrowserSurface` falls back to it when no `services:` is passed, so highlight-to-comment works
  in every browser widget without per-widget wiring. An explicit `services:` still wins. Additive;
  ABI generation `11` is unchanged.
- Add `EnvironmentValues.widgetLinkRouter` (`WidgetLinkRouter`) and `WebSectionLiveView.setLinkRouter(_:)`
  / `load(_:)`. A browser widget's web views offer a clicked link (and `target=_blank` / `window.open`
  popups, but never same-document anchors, redirects or script navigations) to the host before
  navigating in place; returning true cancels the navigation. `BrowserSurface` installs the
  environment router on every web view it shows. Content hosts that set `onOpenLink` are unchanged.
  Additive.
- `ArtifactSnapshotRenderer.render(url:coalescingKey:options:)` takes `Options` (width, height cap,
  `trimsToContentEdge`). The default, `.preview`, is the existing 760pt / 600pt-capped look;
  `.fullPage(width:)` captures the whole page, cropped to where its content ends. Additive.

## 1.1.0

- Add the canonical `work42-plugin-creator` skill, references, and plugin
  template for agent-driven plugin creation and maintenance.
- Align generated plugin manifests with manifest schema v2.
- Retain ABI generation `11`; plugins built for SDK 1.0.0 remain
  binary-compatible.

## 1.0.0

- Initial public `Work42PluginKit` and `Work42UI` release.
- Establish ABI generation `11`.

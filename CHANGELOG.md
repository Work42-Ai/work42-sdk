# Changelog

## Unreleased

- Add `EnvironmentValues.widgetSessionServices`, set by the host around every plugin widget.
  `BrowserSurface` falls back to it when no `services:` is passed, so highlight-to-comment works
  in every browser widget without per-widget wiring. An explicit `services:` still wins. Additive;
  ABI generation `11` is unchanged.

## 1.1.0

- Add the canonical `work42-plugin-creator` skill, references, and plugin
  template for agent-driven plugin creation and maintenance.
- Align generated plugin manifests with manifest schema v2.
- Retain ABI generation `11`; plugins built for SDK 1.0.0 remain
  binary-compatible.

## 1.0.0

- Initial public `Work42PluginKit` and `Work42UI` release.
- Establish ABI generation `11`.

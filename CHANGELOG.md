# Changelog

## 2.1.0

- Retain ABI generation `12`; plugins built for SDK 2.0.0 remain binary-compatible. Every change below is additive.
- **Web app compatibility.** Web-app views and the sign-in popups they open send Safari's own `Version/x Safari/605.1.15`
  user-agent token (the installed Safari's version), so providers that require a supported Safari (Atlassian Cloud)
  stop reporting an unsupported browser. Ephemeral and offscreen web views are unchanged.
- **Deterministic loading and recovery.** `WebSectionLiveView` ignores callbacks from superseded navigations, never
  shows a cancellation as a failure, offers "This page is taking too long" with Retry / Keep waiting after 30 seconds,
  and makes one bounded reload after a web content process crash. A POST is never replayed. New:
  `retry()`, `stopLoading()`, `keepWaiting()`, `isStalled`, `isUnresponsive`, `dismissUnresponsiveNotice()`,
  `didRecoverFromProcessTermination`. `reload()` loads the intended address when nothing is committed yet.
  `WebSectionStatus` is unchanged.
- **Cached state on return.** A cached web section probes responsiveness once when it becomes visible again (five-second
  timeout) and otherwise leaves the page alone; nothing runs while hidden.
- **Address bar search.** New public `BrowserAddressResolver.resolve(_:)`: addresses load directly (http for
  localhost and loopback, https otherwise), phrases become an encoded Google search, unsupported schemes resolve to
  nil. `BrowserWidgetModel.navigateToDraft()` uses it, so every widget on the shared chrome gets it.
- **History.** App web sections enable the native back/forward swipe; the address field keeps an unsubmitted draft
  across page URL changes and shows the right tab's address and history state when rebound.
- `BrowserChromeRow` gains `onStop` (Refresh becomes Stop while loading); `makeWebWidgetChrome` gains `onStop` and
  `webStatus`. All have defaults.

## 2.0.0

- **ABI generation `12`.** `Work42UI` and `Work42PluginKit` are built with Swift library evolution and ship a
  compiler-independent `.swiftinterface`, so a plugin builds with the Swift compiler that built the app **or any
  newer one** (the app used to ship only binary `.swiftmodule`s, which only the exact same compiler could import,
  so plugins failed to build on Macs with a newer Xcode). Plugins built for ABI `11` do not load: reinstall them
  (`work42 plugin install <source>`).
- **Breaking:** `Work42UI` no longer re-exports MarkdownUI or Yams, and `MarkdownUI.Theme.work42` / `.flow42` are
  no longer public, so the plugin contract holds only Work42 types and MarkdownUI/Yams can be upgraded without
  breaking built plugins. Migration:
  - `Markdown(text).markdownTheme(.work42)` → `Work42MarkdownText(text)` (`theme: .flow42` for the alias).
  - `YAMLDecoder().decode(T.self, from: yaml)` → `Work42YAML.decode(T.self, from: yaml)`.
  - `YAMLEncoder().encode(value)` → `Work42YAML.encode(value)`.
  - `Yams.load(yaml: text)` → `Work42YAML.load(text)`.
  - Plugins that need other MarkdownUI or Yams API should render through `MarkdownPreview` /
    `Work42MarkdownDocument`, or open an issue for the missing capability.
- Add `Work42MarkdownText`, `Work42MarkdownTheme` and `Work42YAML`. The host app additionally uses
  `@_spi(Work42Host)` `Work42ParsedMarkdown` and the `init(parsed:theme:bodyFontSize:resolvesLocalFileImages:)`
  initializer; they are not part of the plugin contract.
- The minimum plugin compiler is Swift 6.2 (it must know `-default-isolation`); the interface also records the Swift that
  built the app in its `// swift-compiler-version:` header. Older compilers fail up front with a message naming both.
- Add a `Work42UITests` test target.

## 1.3.0

- Retain ABI generation `11`; plugins built for SDK 1.0.0, 1.1.0 and 1.2.0 remain binary-compatible. This
  release adds documentation, fixes and pinned layouts; it changes no public symbol's layout.
- Document the manifest field `requires` (plugin dependencies), the session-type field `widgets` (the widgets
  its sessions have), `work42 plugin install --path <subdir>`, the `## Prerequisites` skill convention with
  `~/.work42/bin` as the install target for plugin CLIs, the `<plugin>-setup` skill convention for installing them, and
  deregister-then-remove semantics.
- The plugin template and the plugin-creator example widget skill gain `requires: []` and a Prerequisites stub.
- Artifact web views (`WebAppCatalog.artifact(url:)`) no longer paint a background of their own. The canvas
  theme still paints the page background of ordinary artifacts, so they look the same; a page whose `html` and
  `body` are transparent (the meet42 brief and summary) now shows the pane behind it. Other web views (browser,
  Jira, GitHub) are unchanged. No public API change.
- `LinkPolicyProxy` implements every delegate method itself: it forwards while the caller is alive and applies
  WebKit's defaults otherwise (default handling for authentication challenges, allow for navigation responses,
  cancel answers for JavaScript panels and the file picker, no-op for notifications). This fixes
  `doesNotRecognizeSelector` aborts when SwiftUI released the caller during a page load.
- `PublicLayoutStabilityTests` pins the layout of every public struct widgets receive or embed
  (`WidgetBackgroundServices`, `SessionServices` and others), so a stored property added by accident fails the
  test instead of crashing widgets built against another SDK.

## 1.2.0

- Retain ABI generation `11`; plugins built for SDK 1.0.0 and 1.1.0 remain binary-compatible. This
  release only adds symbols.

- Add `WebSectionLiveView.setInterceptAllLinks(_:)`. `BrowserSurface` turns it on whenever the host provides a
  link router, so every web link click (`http`, `https`, `work42`; not `mailto:` or fragments in the current
  document) is offered to the router, including in-page single-page-app clicks, and the host's Open Link
  decides where it opens. A click the router declines is replayed in the page, so the app routes in place as
  before. Option-click always navigates in place. `WidgetLinkRouter.patterns` is kept but no longer used.
  Adds symbols only.

- Add `EnvironmentValues.widgetSessionServices`, set by the host around every plugin widget.
  `BrowserSurface` falls back to it when no `services:` is passed, so highlight-to-comment works
  in every browser widget without per-widget wiring. An explicit `services:` still wins. The
  environment is read inside an internal view, so the public `BrowserSurface` keeps its 384-byte layout
  and widgets built against SDK 1.0/1.1 keep working. (A first version stored the `@Environment` on
  `BrowserSurface` itself, growing it to 624 bytes; widgets built against either SDK crashed when loaded
  by an app with the other.)
- Add `EnvironmentValues.widgetLinkRouter` (`WidgetLinkRouter`) and `WebSectionLiveView.setLinkRouter(_:)`
  / `load(_:)`. A browser widget's web views offer a clicked link (and `target=_blank` / `window.open`
  popups, but never same-document anchors, redirects or script navigations) to the host before
  navigating in place; returning true cancels the navigation. `BrowserSurface` installs the
  environment router on every web view it shows. Content hosts that set `onOpenLink` are unchanged.
  Adds symbols only.
- `ArtifactSnapshotRenderer.render(url:coalescingKey:options:)` takes `Options` (width, height cap,
  `trimsToContentEdge`). The default, `.preview`, is the existing 760pt / 600pt-capped look;
  `.fullPage(width:)` captures the whole page, cropped to where its content ends.
  `render(url:coalescingKey:)` remains as its own overload (a defaulted parameter would have removed
  that symbol).
- Add `PublicLayoutStabilityTests`, pinning the in-memory size of the public structs widgets embed by
  value. Work42PluginKit is not built with library evolution, so changing one is an ABI break.

## 1.1.0

- Add the canonical `work42-plugin-creator` skill, references, and plugin
  template for agent-driven plugin creation and maintenance.
- Align generated plugin manifests with manifest schema v2.
- Retain ABI generation `11`; plugins built for SDK 1.0.0 remain
  binary-compatible.

## 1.0.0

- Initial public `Work42PluginKit` and `Work42UI` release.
- Establish ABI generation `11`.

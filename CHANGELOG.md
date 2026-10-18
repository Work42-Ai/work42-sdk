# Changelog

## 2.6.2

- Retain ABI generation `12`; plugins built for SDK 2.0.0 to 2.6.1 remain binary-compatible. No public API changes.
- **HTML artifact kit, page spacing.** Fragment artifacts are served as `<body><main id="w42-canvas-content">…</main>`, so
  the 2.6.1 page-level rhythm rules (`body > * + *`) only matched `<main>` itself and top-level blocks had no gap. They now
  match the children of both `body` and `#w42-canvas-content`: 16px between top-level blocks and cards, 8px after a
  heading. Still zero-specificity `:where()` rules, so any spacing utility wins.
- **Plugin template.** `skills/work42-plugin-creator/assets/plugin-template/plugin.yaml` declares `sdk_version: 2.6.2`
  (it was left at 2.5.0 by the 2.6.0 and 2.6.1 releases).

## 2.6.1

- Retain ABI generation `12`; plugins built for SDK 2.0.0 to 2.6.0 remain binary-compatible. No public API changes.
- **HTML artifact kit, icons.** The diagram toolbar and tile, the error card and toasts drew blank icons because the kit
  set `--sf` to a relative URL, which a stylesheet resolves against itself (`_w42/kit/_w42/sf/…`, a 404). The URL is now
  resolved against the page. A host's `window.__w42SfBase` still takes priority.
- **HTML artifact kit, code card.** A plain `<pre><code class="language-x">` becomes a card (icon tile, title from
  `data-title` or the language, language badge, copy button, padded body that scrolls sideways) that shares the diagram
  card's frame and header. A block inside an author's own card, a diagram, a document's prose or Mermaid is left alone.
- **HTML artifact kit, default spacing.** Cards are padded 20px, blocks in them 12px apart, a heading 8px from what
  follows, cards and page blocks 16px apart, and plain lists show markers with 6px between items. The rules are
  zero-specificity `:where()` rules, so any spacing utility an author writes wins; flush (`overflow-clip`) cards, flex and
  grid children and lists with a class are left alone.
- **HTML artifacts render at 110%.** `CanvasTheme.tokensCSS()` emits the type tokens (`--w42-f9`…`--w42-f32`), the control
  sizes (`--w42-h-*`) and the radii (`--w42-r-*`) at 110% of the native scale as plain values (body 16.5px), every fixed
  pixel size in the kit CSS is written at 110% (rounded to 0.5px), and the kit sets `html { font-size: 17.6px }` so
  rem-based Tailwind spacing follows. Nothing is computed at runtime. The native `DesignTokens` scale, the frozen legacy
  stylesheet, the spacing tokens, hairlines, shadows, blur radii and the device-mockup hardware are unchanged.

## 2.6.0

- Retain ABI generation `12`; plugins built for SDK 2.0.0 to 2.5.0 remain binary-compatible. Everything below is
  additive public API; the one changed declaration, `ChatBubble`, keeps its previous initializer.
- **`ConversationView`**: one scrolling conversation for the agent chat and the meeting transcript. It windows long
  conversations (only the newest page is laid out and older pages load automatically near the top, keeping the reader's
  place), follows new items only while the user is at the bottom, and shows a "Jump to latest" pill with the count of
  unseen items when they are not. Rows are built per item with a `ConversationRowContext`; `ConversationBubble` places
  a `ChatBubble` for it; `ConversationDateDivider` is the shared time divider.
- **Labels by actor count.** With one other actor a conversation is sides only. With three or more distinct actors
  (counted over the whole conversation) every run from a non-me actor shows a 32pt avatar, a coloured name and a time.
  The pure rules live in `ConversationLayout` and are unit tested.
- **`GlassAvatar`**: the one avatar look, a liquid-glass circle tinted with a single plain colour and the initials in
  that colour (a material fallback before macOS 26). `ChatBubble` now draws its header avatar with it, and gains an
  `avatarSize` initializer parameter (default 22, unchanged footprint).
- **Profile photos and who is signed in.** `GlassAvatar` gains an `imageURL` initializer: the photo is clipped to a
  circle inside the glass ring, loaded once per URL through the shared `GlassAvatarImageCache` (a failed URL is
  remembered and not retried), with the initials shown until it arrives or if it never does. `ConversationActor` gains
  an `imageURL`. In Work42PluginKit, `SessionServices.account` (computed, backed by `WidgetAccountRegistry`, which the
  host sets at startup; `WidgetAccountService.currentUser()` returns a `WidgetAccountUser` with display name, email and
  photo URL) lets a widget show "you". It is `nil` on hosts without it. `SessionServices` gets no stored property, so its
  layout (and every plugin built against an earlier SDK) is unchanged. **Privacy:** every installed plugin can now read
  the signed-in user's display name, email and profile photo URL. Plugins already run shell commands as the user, so
  this adds no new capability, but it is a new, explicit data surface.
- **`ConversationLabels`.** `ConversationView` takes `labels: .automatic` (default: avatars and names from three actors,
  never on my lines, as in the agent chat) or `.always` (every run labeled whatever the number of actors, mine included,
  with my label and avatar on the trailing side: the meeting transcript). `ConversationRowContext` gains `labelsMe`,
  with its previous initializer kept.
- **A mouse wheel now counts as the user scrolling.** The scroll probe also watches wheel events that land inside its
  scroll view (trackpad and scrollbar gestures keep using the live-scroll notifications), so a wheel scroll can unpin the
  view and load older pages.

## 2.5.0

- Retain ABI generation `12`; plugins built for SDK 2.0.0 to 2.4.1 remain binary-compatible. The source-level changes
  below affect only hosts that call the artifact, markdown or card APIs directly; no plugin, template or Work42 host
  code used the removed declarations.
- **A new design kit for artifacts and documents.** Preline UI 4.2 and Tailwind v4 replace the hand-built Web Kit.
  `Resources/kit/` carries vendored Preline, a Work42 theme that maps the type scale (`text-2xs` to `text-4xl`), the
  semantic colours, radii and shadows onto the app's `--w42-*` tokens (so light, dark and the system accent drive
  everything), the `wk-*` recipe layer (liquid-glass buttons, segmented control, fields, badges, cards, menus, toasts),
  a precompiled `w42-kit-full.css` and a reference gallery (`kit/w42-gallery.html`). Agents write Tailwind and Preline
  markup and `<i data-sf="…">` SF Symbols; the three kept components are `<w42-diagram>`, `<w42-mockup>` and
  `<w42-flutter-mockup>`, rebuilt on the kit. Artifacts saved before the kit keep rendering with a frozen copy of the
  old Web Kit (`kit/legacy/`).
- **Token-only theme.** `CanvasTheme.tokensCSS()` emits the `--w42-*` tokens (light on `:root`, dark on `.dark`, live
  accent, and a readable `--w42-on-accent`). `CanvasTemplate.composeKit` and `composeLegacy` build the artifact page;
  `ArtifactShellAssets` serves the kit files (`_w42/kit/*`, `_w42/legacy/*`) and `SFSymbolRenderer` (moved here from the
  app) draws SF Symbols as PNGs for `_w42/sf/<name>.png`.
- **Markdown documents on the kit**, with the comment capsule now the native SwiftUI `Work42CommentCapsule`, placed
  over the web view from the page's selection rect.
- **Artifact tiles.** `ArtifactPreviewCard` no longer previews the content: it is a tile (a tilted 3D object in the
  artifact's colour carrying its type icon, the title, and "Kind · age") on the design system's liquid-glass card
  surface, with a glass Open button and, when the host supplies `onExport`, an export button. New:
  `ArtifactCardAppearance`, `ArtifactExportFormat` (HTML, Markdown, PDF), `ArtifactExportButton` and
  `ArtifactExportPopover`. The host does the exporting.
- **The glass logo loader on web content.** The native web view loading and stalled overlays and the browser toolbar
  use `LoadingIndicator`; the kit's `.wk-loader` is its web twin, used by the device mockup.
- **Removed or changed public API** (none used by plugins or templates): `ArtifactPreviewCard.PreviewState`,
  `.state`, `.reloadToken` and `SizeMode.narrowThreshold` (the card takes an `ArtifactCardAppearance`);
  `CanvasTheme.css()` (use `tokensCSS()`, or `legacyCSS()` for the old output);
  `CanvasTemplate.compose(content:themeCSS:)` (use `composeKit` or `composeLegacy`). The old `w42-components.css/js`
  and `w42-gallery.html` resources are gone from the bundle root (the frozen copies live under `kit/legacy/`).
  `MarkdownResources.init` gained an optional `symbolPNG` parameter (source-compatible).

## 2.4.1

- Retain ABI generation `12`; no API changes.
- **The web view on screen is always the live view the host hands to `CachedWebSectionView`.** A host that rebuilt a
  cached view for the same tab used to leave the old web view showing while the new one, which the host's Refresh,
  Stop and address bar drive, never got a window; a view without a window holds loads back, so a page could appear
  never to load. The view is now identified by the live view it shows.
- Torn-down view actions, loads held for want of a window and their replay are logged at `notice` level (subsystem
  `com.work42.browser`, host names only) so a recurrence can be read from the system log.

## 2.4.0

- Retain ABI generation `12`; plugins built for SDK 2.0.0 to 2.3.1 remain binary-compatible. Every change below is
  additive, except that `CanvasTemplate.componentsJS` is deprecated and now empty (see the last item).
- **The Web Kit, rebuilt on Liquid Glass.** Artifacts and markdown surfaces share one stylesheet and one tag
  runtime. New `<w42-*>` tags cover controls (button, tabs, toolbar, chip, field, progress, spinner, disclosure,
  empty state), containers (card, group, list, metric, callout), overlays (popover, menu, dialog, sheet, toast,
  tooltip), spec and document pages (hero, table of contents, numbered section, acceptance criteria) and layout
  (`w42-stack`, `w42-cluster`), with automatic vertical rhythm. An invalid attribute value logs
  `w42 component error [<tag>]` and falls back to the tag's default instead of failing. `w42-gallery.html`, bundled
  as a resource, renders every family.
- **Plain HTML renders on the kit.** Unclassed buttons, inputs, tables, code, quotes and the rest take the kit's
  look through zero-specificity element defaults, so agent markup needs no styling of its own. Type now mirrors the
  native chat text: primary-colour paragraphs, a 16 px body at about 1.55 line height, the chat heading scale and
  system font smoothing.
- **Tokens.** `CanvasTheme.css()` emits 34 new colour tokens (labels, fills, table, field, glass, materials, chip
  and the 42 capsule tint), fixed metrics, and a shared motion set (`--w42-spring`, `--w42-ease`,
  `--w42-dur-fast|base|slow`, collapsed under `prefers-reduced-motion`). Translucent colours are written as
  `#rrggbbaa`, and `currentColorTokens()` carries every colour token into a live theme push.
- **One tag runtime.** `w42-components.js` now registers every tag, including `w42-code`, `w42-table`,
  `w42-mockup`, `w42-flutter-mockup` and the new `w42-diagram`, replacing the inline script the shell used to carry.
  `window.__w42.theme.apply` and `window.__w42FlutterMockup` behave as before. New `ArtifactShellAssets`
  accessors: `componentJSData()`, `componentJSAssetPath` and `galleryPath()`, plus
  `CanvasTemplate.componentLibraryJS()`.
- **A native comment capsule.** New `Work42CommentCapsule` (SwiftUI) is the 42 brand mark on tinted Liquid Glass,
  with a label that opens on hover and stays open, a spring pop-in and a press squish. It replaces the accent
  `plus.bubble.fill` button for highlight-to-comment, and `View.work42CentredOnSelection(_:gap:)` centres it above
  a selection. Matching `<w42-capsule label size>` tag for web content. The brand mark ships as the bundled
  resource `work42-mark42.png`.
- **Deprecated: `CanvasTemplate.componentsJS`.** The tag runtime moved into `w42-components.js`, so this
  constant is now an empty string kept only so existing references still link. Use `componentLibraryJS()`.

## 2.3.1

- Retain ABI generation `12`; no API changes.
- **A browser page that comes back on screen is checked and repainted.** When a cached page becomes visible again,
  or its view is hosted again (the Home page re-mounts its widgets when you return to it), a view whose state says
  the page is loaded but which holds no page loads its last address again, and a loaded page is repainted so it
  does not read blank. The repaint keeps the scroll position of the page's own scroll panes. Each return is
  logged to the unified log (subsystem `com.work42.browser`), with host names only.

## 2.3.0

- Retain ABI generation `12`; plugins built for SDK 2.0.0 to 2.2.0 remain binary-compatible. Every change below is
  additive.
- **Open in New Tab from the right-click menu.** Right-clicking a link in a widget's web view, when that widget
  owns the link, retitles WebKit's "Open Link in New Window" item to "Open in New Tab in <widget>" and puts it
  first. Choosing it opens the link through the widget's own link handler as a tab of its own, never as a popup
  window, so a link that stays in the current tab (see `isSamePage` in 2.2.0) can still be split off. Other
  popups, such as sign-in windows, behave as before. `WebLinkHandler` gains an overload with `ownsHere` and
  `title` (the existing initializer is unchanged); a host that does not supply them gets WebKit's menu.

## 2.2.0

- Retain ABI generation `12`; plugins built for SDK 2.0.0 and 2.1.0 remain binary-compatible. Every change below is
  additive.
- **Same-page links.** New optional `Work42Widget.isSamePage(_:as:)` (default `false`). When a link is clicked in a
  widget that owns it and the widget says it is the same page as the one shown, Open Link keeps it in the current tab
  instead of calling the widget's `linkIntents`.
- **A browser widget can no longer get stuck on the loader.**
  - `BrowserSurface` rebuilds its model and web views when its cache entry is torn down while it is on screen (a
    widget `deactivate()` around a session visit), and runs `configure` again for the rebuilt model. Before, it
    showed a spinner forever with no Refresh.
  - `WebSectionLiveView` gains `isTornDown` and ignores load, reload, retry, stop and keep-waiting once torn down;
    `BrowserSurfaceCache` never hands back a torn-down view.
  - One second after WebKit goes idle with the status still loading, the status is corrected from what the view
    shows (loaded with a page, failed with Retry without). A load waiting for a hidden view to get a window, and a
    slow load WebKit is still running, are left alone.

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

// ReExports.swift — MarkdownUI and Yams both ship INSIDE Work42UI.framework
// and are re-exported here, so app-side consumers (Flow42Core, Work42App,
// flow42, ThemeYAML) reach their APIs via `import Work42UI` and resolve
// symbols from this framework's one embedded copy. No main-package target
// may declare MarkdownUI or Yams as a direct dependency — that would
// statically link a second copy into the consuming binary and reintroduce
// the duplicate-metadata crash class (two copies of the same Swift type
// metadata/conformances) this sub-package split exists to prevent.
//
// Yams specifically (feat/custom-widgets.5): Flow42Core/flow42/Work42App
// used to declare Yams directly (pre-dating this SDK). Once ThemeYAML
// (inside this package) needed Yams too, the SAME module existed twice in
// any binary linking both — reproducibly visible as an ObjC runtime
// "Class ... is implemented in both libWork42UI.dylib and <binary>"
// warning on every `swift build`/`swift test`/CLI invocation (silently
// absent from the xcodebuild-packaged app only because Xcode's package
// graph coalesces shared products differently — see
// docs/reference in project memory). Routing everyone through this
// re-export is the actual fix, not a xcodebuild-only workaround.
//
// cmark-gfm is deliberately NOT re-exported: it's an implementation detail
// of MarkdownHTMLConverter with no consumers outside this module.

@_exported import MarkdownUI
@_exported import Yams

// MarkdownViewMode.swift - The shared Preview / Source view mode for
// markdown surfaces (the spec widget and `.md` files in the File widget).
//
// The raw `String` values are STABLE on purpose: they back an
// `@AppStorage` global preference (AC6), so renaming a case must never
// change its stored value. `Preview` is the default and sits first in
// the toggle (AC3).

import Foundation

public enum MarkdownViewMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    /// Rich rendered markdown (MarkdownUI `.work42` theme), read-only.
    case preview = "preview"
    /// The existing per-widget source editor.
    case source = "source"

    public var id: String { rawValue }

    /// Human-facing label, fed to `GlassTabStrip`'s `label:` closure.
    public var label: String {
        switch self {
        case .preview: return "Preview"
        case .source: return "Source"
        }
    }

    /// The default mode the first time a markdown surface is shown (AC3).
    public static var defaultMode: MarkdownViewMode { .preview }
}

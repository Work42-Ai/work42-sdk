// PlatformImage.swift — NSImage on macOS, UIImage on iPadOS, behind one spelling.

import SwiftUI

#if canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformView = NSView
public typealias PlatformWindow = NSWindow
#else
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformView = UIView
public typealias PlatformWindow = UIWindow
#endif

extension PlatformImage {

    /// The image stored at `url`, or nil.
    public nonisolated static func loadFile(at url: URL) -> PlatformImage? {
        #if canImport(AppKit)
        NSImage(contentsOf: url)
        #else
        UIImage(contentsOfFile: url.path)
        #endif
    }

    /// An SF Symbol as an image.
    public nonisolated static func symbol(named name: String) -> PlatformImage? {
        #if canImport(AppKit)
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
        #else
        UIImage(systemName: name)
        #endif
    }

    /// The image flagged as a template (recolored by `foregroundStyle`) or as plain artwork.
    public nonisolated func asTemplate(_ template: Bool) -> PlatformImage {
        #if canImport(AppKit)
        isTemplate = template
        return self
        #else
        withRenderingMode(template ? .alwaysTemplate : .alwaysOriginal)
        #endif
    }
}

extension Image {
    /// A SwiftUI image from the platform image class.
    public nonisolated init(platformImage image: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

#if canImport(AppKit)
public typealias PlatformViewRepresentable = NSViewRepresentable
#else
public typealias PlatformViewRepresentable = UIViewRepresentable
#endif

public enum PlatformFontMetrics {
    /// Height of the system font's line box at `size`.
    public static func systemLineBoundsHeight(ofSize size: CGFloat) -> CGFloat {
        #if canImport(AppKit)
        NSFont.systemFont(ofSize: size).boundingRectForFont.height
        #else
        UIFont.systemFont(ofSize: size).lineHeight
        #endif
    }
}

@MainActor
public enum PlatformPasteboard {
    /// Replaces the clipboard with `string`.
    public static func copy(_ string: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

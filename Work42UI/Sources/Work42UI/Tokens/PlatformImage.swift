// PlatformImage.swift — NSImage on macOS, UIImage on iPadOS, behind one spelling.

import SwiftUI

#if canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

extension PlatformImage {

    /// The image stored at `url`, or nil.
    public static func loadFile(at url: URL) -> PlatformImage? {
        #if canImport(AppKit)
        NSImage(contentsOf: url)
        #else
        UIImage(contentsOfFile: url.path)
        #endif
    }

    /// An SF Symbol as an image.
    public static func symbol(named name: String) -> PlatformImage? {
        #if canImport(AppKit)
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
        #else
        UIImage(systemName: name)
        #endif
    }

    /// The image flagged as a template (recolored by `foregroundStyle`) or as plain artwork.
    public func asTemplate(_ template: Bool) -> PlatformImage {
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
    public init(platformImage image: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

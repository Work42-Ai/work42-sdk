// WebAppBrowserConfiguration.swift — the one place a web-app view's browser identity is decided (WOR-110).
//
// WKWebView's default user agent has no `Version/x Safari/x` token, so providers that sniff for a supported
// Safari (Atlassian Cloud) report an unsupported browser even though the engine has every capability they
// need. This adds the token Safari itself sends, using the version of the Safari installed on this Mac. Nothing
// else changes: no spoofed methods, no extra headers, no TLS or data-store changes. When Safari cannot be read
// the user agent is left at WebKit's default rather than invented.
//
// Applied to the configuration before the web view exists (so before its first request) for web-app views and
// for the sign-in popups they open, so opener and popup report the same identity. Offscreen renderers and
// ephemeral local content never use it.

import Foundation
import WebKit

enum WebAppBrowserConfiguration {
    /// WebKit's frozen compatibility token, identical in every Safari build.
    static let webKitToken = "605.1.15"

    /// Safari's marketing version on this Mac (e.g. "26.4"), nil when Safari is not installed or unreadable.
    static let installedSafariVersion: String? = {
        let url = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: url),
              let version = info["CFBundleShortVersionString"] as? String else { return nil }
        return validated(version)
    }()

    /// The `applicationNameForUserAgent` value for a given Safari version; nil if the version is malformed.
    static func applicationName(safariVersion: String?) -> String? {
        guard let version = safariVersion.flatMap(validated) else { return nil }
        return "Version/\(version) Safari/\(webKitToken)"
    }

    static func apply(to configuration: WKWebViewConfiguration, safariVersion: String? = installedSafariVersion) {
        guard let name = applicationName(safariVersion: safariVersion) else { return }
        configuration.applicationNameForUserAgent = name
    }

    /// Whether `configuration` already carries the web-app identity (a popup's opener was a web-app view).
    static func isApplied(to configuration: WKWebViewConfiguration, safariVersion: String? = installedSafariVersion) -> Bool {
        guard let name = applicationName(safariVersion: safariVersion) else { return false }
        return configuration.applicationNameForUserAgent == name
    }

    /// Dotted numeric versions only ("17", "26.4", "18.5.1").
    private static func validated(_ version: String) -> String? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        return version
    }
}

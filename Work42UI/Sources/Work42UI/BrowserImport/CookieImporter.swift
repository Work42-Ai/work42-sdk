// CookieImporter.swift - brings a browser's sign-in cookies into every persistent web view (WOR-417).
//
// All or nothing: the cookies are read first (on a background task, since the Keychain prompt and the file
// copies can take a while); only when that succeeds are they written into every persistent WKWebsiteDataStore
// Work42 has, overwriting same name+domain+path. Then every open persistent web view reloads.
// Cookie names and values are never logged: log lines carry the browser and a count.

import Foundation
import OSLog
import WebKit

extension Notification.Name {
    /// Posted after an import has written its cookies, so persistent web views can reload.
    public nonisolated static let work42BrowserCookiesImported = Notification.Name("work42BrowserCookiesImported")
}

@MainActor
public enum CookieImporter {
    private static let log = Logger(subsystem: "com.work42.browser", category: "import")

    /// Imports every non-expired cookie of `profile`, returning how many were written.
    public static func importCookies(from browser: ImportableBrowser, profile: BrowserProfile) async throws -> Int {
        let cookies = try await Task.detached(priority: .userInitiated) {
            try readCookies(from: browser, profile: profile)
        }.value
        guard !cookies.isEmpty else { throw CookieImportError.noCookies }

        // Every store Work42 has, plus the Browser widget's own (it may not exist on disk yet).
        var identifiers = Set(await WKWebsiteDataStore.allDataStoreIdentifiers)
        identifiers.insert(WebSectionView.stableIdentifier(forKey: "browser"))
        for identifier in identifiers {
            let store = WKWebsiteDataStore(forIdentifier: identifier).httpCookieStore
            for cookie in cookies { await store.setCookie(cookie) }
        }
        log.info("imported \(cookies.count) cookies from \(browser.displayName) into \(identifiers.count) stores")
        NotificationCenter.default.post(name: .work42BrowserCookiesImported, object: nil)
        return cookies.count
    }

    private nonisolated static func readCookies(from browser: ImportableBrowser, profile: BrowserProfile) throws -> [HTTPCookie] {
        do {
            switch browser {
            case .safari: return try SafariCookieReader.read(profile)
            case .firefox: return try FirefoxCookieReader.read(profile)
            case .chrome, .arc, .brave, .edge, .chromium: return try ChromiumCookieReader.read(profile, browser: browser)
            }
        } catch let error as CookieImportError {
            throw error
        } catch {
            throw CookieImportError.unreadable(error.localizedDescription)
        }
    }
}

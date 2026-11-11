// SignInCookies.swift — moving a Mac's Work42 sign-ins to another device of the same owner, once (WOR-601).
//
// The Mac's importer brings another browser's cookies into every persistent Work42 web store. This is its sibling for a device that
// has no other browser to read: the Mac exports the cookies already in its Work42 web stores (the logins the person made in its
// widgets), and the device writes them into its own stores the same way, then every open persistent web view reloads. Cookie names
// and values are never logged: log lines carry a count. It is a copy at one moment, not a sync.

import Foundation
import OSLog
import WebKit

/// One cookie as it travels. `HTTPCookie` is not `Codable`, and only the fields a store needs go.
nonisolated public struct SignInCookie: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    /// Seconds since 1970; nil for a session cookie.
    public var expires: Double?
    public var secure: Bool
    public var httpOnly: Bool
    public var sameSite: String?

    public init(
        name: String, value: String, domain: String, path: String, expires: Double? = nil, secure: Bool = false,
        httpOnly: Bool = false, sameSite: String? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
    }

    public init(_ cookie: HTTPCookie) {
        self.init(
            name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
            expires: cookie.expiresDate?.timeIntervalSince1970, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly,
            sameSite: cookie.sameSitePolicy?.rawValue)
    }

    /// The cookie again; nil for one a store would not take (no name or domain).
    public var httpCookie: HTTPCookie? {
        guard !name.isEmpty, !domain.isEmpty else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path.isEmpty ? "/" : path]
        if let expires { properties[.expires] = Date(timeIntervalSince1970: expires) }
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite { properties[.sameSitePolicy] = HTTPCookieStringPolicy(rawValue: sameSite) }
        return HTTPCookie(properties: properties)
    }
}

nonisolated public struct SignInCookieExport: Codable, Sendable, Equatable {
    public var cookies: [SignInCookie]
    public init(cookies: [SignInCookie] = []) { self.cookies = cookies }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> SignInCookieExport? { try? JSONDecoder().decode(SignInCookieExport.self, from: data) }
}

extension Notification {
    /// The `userInfo` key of `.work42BrowserCookiesImported` that lists the data-store keys an import was aimed at (a `[String]`).
    /// A notification without it was an import into every store, and every persistent web view reloads.
    nonisolated public static let work42DataStoreKeysUserInfoKey = "dataStoreKeys"
}

@MainActor
public enum SignInCookieStore {
    private static let log = Logger(subsystem: "com.work42.browser", category: "signin-copy")

    /// The most cookies an export carries; a device with more keeps the first of them.
    public static let maxCookies = 10_000

    /// Every unexpired cookie in every persistent web store this device has, one per name, domain and path.
    public static func exportAll() async -> SignInCookieExport {
        var identifiers = Set(await WKWebsiteDataStore.allDataStoreIdentifiers)
        identifiers.insert(WebSectionView.stableIdentifier(forKey: WebAppCatalog.browserDataStoreKey))
        var seen = Set<String>()
        var cookies: [SignInCookie] = []
        for identifier in identifiers.sorted(by: { $0.uuidString < $1.uuidString }) {
            for cookie in await WKWebsiteDataStore(forIdentifier: identifier).httpCookieStore.allCookies() {
                if let expires = cookie.expiresDate, expires <= Date() { continue }
                guard seen.insert("\(cookie.name)\u{0}\(cookie.domain)\u{0}\(cookie.path)").inserted else { continue }
                cookies.append(SignInCookie(cookie))
                if cookies.count >= maxCookies { return SignInCookieExport(cookies: cookies) }
            }
        }
        return SignInCookieExport(cookies: cookies)
    }

    /// Writes the cookies into every persistent store this device has, and into the stores of `keys` (they may not exist yet),
    /// overwriting the same name, domain and path; then every open persistent web view reloads. Returns how many were written.
    @discardableResult
    public static func install(_ export: SignInCookieExport, alsoInto keys: [String] = []) async -> Int {
        let cookies = export.cookies.prefix(maxCookies).compactMap(\.httpCookie)
        guard !cookies.isEmpty else { return 0 }
        var identifiers = Set(await WKWebsiteDataStore.allDataStoreIdentifiers)
        identifiers.insert(WebSectionView.stableIdentifier(forKey: WebAppCatalog.browserDataStoreKey))
        for key in keys { identifiers.insert(WebSectionView.stableIdentifier(forKey: key)) }
        for identifier in identifiers {
            let store = WKWebsiteDataStore(forIdentifier: identifier).httpCookieStore
            for cookie in cookies { await store.setCookie(cookie) }
        }
        log.info("installed \(cookies.count) cookies into \(identifiers.count) stores")
        NotificationCenter.default.post(name: .work42BrowserCookiesImported, object: nil)
        return cookies.count
    }

    /// The stores `install(_:onlyInto:)` has written to, kept for the life of the process. A persistent store whose last instance is
    /// released drops a cookie that was written to it and never opened by a web view (measured: it reads back empty), so an import
    /// into a store nobody has opened yet must keep the store alive. A web view opened later shares it by identifier.
    private static var retained: [UUID: WKWebsiteDataStore] = [:]

    private static func retainedStore(forKey key: String) -> WKWebsiteDataStore {
        let identifier = WebSectionView.stableIdentifier(forKey: key)
        if let kept = retained[identifier] { return kept }
        let made = WKWebsiteDataStore(forIdentifier: identifier)
        retained[identifier] = made
        return made
    }

    /// Writes the cookies into the stores of `keys` and no others, overwriting the same name, domain and path; then only the open
    /// persistent web views on those stores reload. A device that keeps one set of stores per account uses this, so one account's
    /// import never touches another's. Returns how many cookies were written; names and values are never logged.
    @discardableResult
    public static func install(_ export: SignInCookieExport, onlyInto keys: [String]) async -> Int {
        let cookies = export.cookies.prefix(maxCookies).compactMap(\.httpCookie)
        guard !cookies.isEmpty, !keys.isEmpty else { return 0 }
        for key in keys {
            let dataStore = retainedStore(forKey: key)
            for cookie in cookies { await dataStore.httpCookieStore.setCookie(cookie) }
        }
        log.info("installed \(cookies.count) cookies into \(keys.count) named stores")
        NotificationCenter.default.post(
            name: .work42BrowserCookiesImported, object: nil, userInfo: [Notification.work42DataStoreKeysUserInfoKey: keys])
        return cookies.count
    }
}

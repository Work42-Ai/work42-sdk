// FirefoxCookieReader.swift - cookies from a Firefox profile's cookies.sqlite (WOR-417). Firefox does not encrypt them.

import Foundation

public nonisolated enum FirefoxCookieReader {

    public static func read(_ profile: BrowserProfile) throws -> [HTTPCookie] {
        try read(cookiesURL: profile.cookiesURL, now: Date())
    }

    static func read(cookiesURL: URL, now: Date) throws -> [HTTPCookie] {
        let copy = try DatabaseCopy(copying: cookiesURL, browser: "Firefox")
        defer { copy.cleanup() }
        let database = try SQLiteDatabase(path: copy.url.path)

        var cookies: [HTTPCookie] = []
        try database.rows("SELECT host, name, value, path, expiry, isSecure, isHttpOnly, sameSite FROM moz_cookies") { row in
            let expires = expiryDate(row.int64(4))
            guard !ImportedCookie.isExpired(expires, now: now),
                  let cookie = ImportedCookie.make(
                    domain: row.text(0), name: row.text(1), value: row.text(2), path: row.text(3), expires: expires,
                    secure: row.int64(5) != 0, httpOnly: row.int64(6) != 0, sameSite: sameSite(row.int64(7))
                  ) else { return }
            cookies.append(cookie)
        }
        return cookies
    }

    /// Seconds since 1970; Firefox 116 and later may store milliseconds, which no real date in seconds reaches
    /// (10^11 seconds is the year 5138). 0 is a session cookie.
    static func expiryDate(_ raw: Int64) -> Date? {
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 100_000_000_000 ? Double(raw) / 1000 : Double(raw))
    }

    /// `sameSite`: 0 none, 1 lax, 2 strict.
    private static func sameSite(_ value: Int64) -> String? {
        switch value {
        case 1: "lax"
        case 2: "strict"
        default: nil
        }
    }
}

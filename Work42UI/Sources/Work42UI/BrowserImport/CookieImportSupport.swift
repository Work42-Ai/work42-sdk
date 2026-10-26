// CookieImportSupport.swift - what the three cookie readers share (WOR-417): the error type, building an
// HTTPCookie, a read-only SQLite wrapper and the temp copy of a browser's database.
//
// Nothing here logs a cookie name or value. Log lines elsewhere carry a browser and a count only.

import Foundation
import SQLite3

public nonisolated enum CookieImportError: Error, Equatable, Sendable {
    /// The user declined the Keychain prompt for the browser's "Safe Storage" key.
    case keychainDenied
    /// macOS blocked reading the browser's cookie file (Safari's container needs Full Disk Access).
    case fullDiskAccessRequired
    /// The data could not be read or made sense of; the message says why.
    case unreadable(String)
    /// The browser had no cookies to import.
    case noCookies
}

nonisolated enum ImportedCookie {

    /// A cookie from a browser's store as an `HTTPCookie`, or nil when the values cannot form one.
    /// `expires` nil is a session cookie. `sameSite` is "lax" or "strict"; anything else is left unset.
    static func make(
        domain: String, name: String, value: String, path: String,
        expires: Date?, secure: Bool, httpOnly: Bool, sameSite: String?
    ) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .name: name,
            .value: value,
            .path: path.isEmpty ? "/" : path,
        ]
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires { properties[.expires] = expires }
        switch sameSite {
        case "lax": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
        case "strict": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
        default: break
        }
        return HTTPCookie(properties: properties)
    }

    /// Whether an expiry that is set has already passed (a nil expiry is a session cookie and is kept).
    static func isExpired(_ expires: Date?, now: Date) -> Bool {
        guard let expires else { return false }
        return expires <= now
    }

    /// Whether `error` is macOS refusing to let the app read a protected file.
    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionDenied(underlying) }
        return false
    }
}

/// A browser's cookie database, copied to a private temp folder (with its write-ahead log, which holds the newest
/// cookies while the browser is open and locks the original) and removed again by `cleanup()`.
nonisolated struct DatabaseCopy {
    let url: URL
    private let folder: URL

    init(copying source: URL, browser: String) throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("work42-cookie-import-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: url)
            let wal = URL(fileURLWithPath: source.path + "-wal")
            if FileManager.default.fileExists(atPath: wal.path) {
                try FileManager.default.copyItem(at: wal, to: URL(fileURLWithPath: url.path + "-wal"))
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if ImportedCookie.isPermissionDenied(error) { throw CookieImportError.fullDiskAccessRequired }
            throw CookieImportError.unreadable("\(browser)'s cookie file could not be copied.")
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: folder) }
}

/// Just enough SQLite to read rows. Opens a copy the importer owns, so read-write is safe and lets SQLite create the
/// shared-memory file a write-ahead log needs.
nonisolated final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw CookieImportError.unreadable("The cookie database could not be opened.")
        }
    }

    deinit { sqlite3_close(handle) }

    struct Row {
        fileprivate let statement: OpaquePointer

        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }

        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }

        func data(_ column: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    /// Runs `sql` and hands each row to `body`. A statement SQLite cannot prepare (a missing table, a corrupt file)
    /// is reported as unreadable.
    func rows(_ sql: String, _ body: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw CookieImportError.unreadable("The cookie database is damaged or in an unexpected format.")
        }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try body(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw CookieImportError.unreadable("The cookie database could not be read.")
            }
        }
    }
}

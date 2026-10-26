// SafariCookieReader.swift - cookies from Safari's Cookies.binarycookies (WOR-417).
//
// The file is a small binary format: the magic "cook", a big-endian page count and page sizes, then the pages.
// Each page has a big-endian-looking header (0x00000100), a little-endian cookie count and cookie offsets, and
// the cookie records. A record is little-endian: size, flags (1 secure, 4 HttpOnly), four string offsets (domain,
// name, path, value) from the record start, and the expiry as seconds since 2001-01-01 in a little-endian Double.
// Safari's container is protected by macOS: reading it without Full Disk Access fails with a permission error.

import Foundation

public nonisolated enum SafariCookieReader {

    public static func read(_ profile: BrowserProfile) throws -> [HTTPCookie] {
        let data: Data
        do {
            data = try Data(contentsOf: profile.cookiesURL)
        } catch {
            if ImportedCookie.isPermissionDenied(error) { throw CookieImportError.fullDiskAccessRequired }
            throw CookieImportError.unreadable("Safari's cookie file could not be read.")
        }
        return try parse(data, now: Date())
    }

    static func parse(_ data: Data, now: Date) throws -> [HTTPCookie] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Array(bytes[0..<4]) == Array("cook".utf8) else {
            throw CookieImportError.unreadable("Safari's cookie file is not in the expected format.")
        }
        let pageCount = Int(try readU32(bytes, 4, bigEndian: true))
        var pageSizes: [Int] = []
        for index in 0..<pageCount { pageSizes.append(Int(try readU32(bytes, 8 + index * 4, bigEndian: true))) }

        var cookies: [HTTPCookie] = []
        var pageStart = 8 + pageCount * 4
        for size in pageSizes {
            guard pageStart + size <= bytes.count else { throw damaged }
            cookies += try parsePage(bytes, start: pageStart, now: now)
            pageStart += size
        }
        return cookies
    }

    private static func parsePage(_ bytes: [UInt8], start: Int, now: Date) throws -> [HTTPCookie] {
        guard try readU32(bytes, start, bigEndian: true) == 0x0000_0100 else { throw damaged }
        let count = Int(try readU32(bytes, start + 4, bigEndian: false))
        var cookies: [HTTPCookie] = []
        for index in 0..<count {
            let record = start + Int(try readU32(bytes, start + 8 + index * 4, bigEndian: false))
            if let cookie = try parseRecord(bytes, at: record, now: now) { cookies.append(cookie) }
        }
        return cookies
    }

    private static func parseRecord(_ bytes: [UInt8], at record: Int, now: Date) throws -> HTTPCookie? {
        let flags = try readU32(bytes, record + 8, bigEndian: false)
        let domain = try readString(bytes, at: record + Int(try readU32(bytes, record + 16, bigEndian: false)))
        let name = try readString(bytes, at: record + Int(try readU32(bytes, record + 20, bigEndian: false)))
        let path = try readString(bytes, at: record + Int(try readU32(bytes, record + 24, bigEndian: false)))
        let value = try readString(bytes, at: record + Int(try readU32(bytes, record + 28, bigEndian: false)))
        let expirySeconds = Double(bitPattern: UInt64(try readU32(bytes, record + 40, bigEndian: false))
            | UInt64(try readU32(bytes, record + 44, bigEndian: false)) << 32)
        let expires: Date? = expirySeconds > 0 ? Date(timeIntervalSinceReferenceDate: expirySeconds) : nil
        guard !ImportedCookie.isExpired(expires, now: now) else { return nil }
        return ImportedCookie.make(
            domain: domain, name: name, value: value, path: path, expires: expires,
            secure: flags & 1 != 0, httpOnly: flags & 4 != 0, sameSite: nil
        )
    }

    // MARK: Bytes

    private static var damaged: CookieImportError {
        .unreadable("Safari's cookie file is damaged.")
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int, bigEndian: Bool) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { throw damaged }
        let slice = bytes[offset..<offset + 4].map(UInt32.init)
        return bigEndian
            ? slice[0] << 24 | slice[1] << 16 | slice[2] << 8 | slice[3]
            : slice[3] << 24 | slice[2] << 16 | slice[1] << 8 | slice[0]
    }

    private static func readString(_ bytes: [UInt8], at offset: Int) throws -> String {
        guard offset >= 0, offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { throw damaged }
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }
}

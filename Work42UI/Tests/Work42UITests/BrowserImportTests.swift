// BrowserImportTests.swift - WOR-417: the sign-in import engine's readers and profile discovery.
//
// Every fixture is built here, in a temp folder: a Safari Cookies.binarycookies written in the real format, a
// Chromium cookie database with values encrypted by the same AES path the reader decrypts, and a Firefox
// cookies.sqlite. Nothing touches the Keychain or the user's browsers.

import CommonCrypto
import Foundation
import SQLite3
import Testing
@testable import Work42UI

// MARK: - Fixtures

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let future = now.addingTimeInterval(86_400 * 30)
private let past = now.addingTimeInterval(-86_400)

private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("work42-import-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func touch(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data())
}

/// Runs SQL against a new database at `url`.
private func makeDatabase(at url: URL, _ statements: [String]) throws {
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    defer { sqlite3_close(handle) }
    for statement in statements {
        #expect(sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK, "\(statement)")
    }
}

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

// MARK: Safari

/// Writes the Cookies.binarycookies format one cookie per page.
private struct SafariFixture {
    struct Cookie {
        var domain, name, path, value: String
        var secure = false, httpOnly = false
        var expires: Date?
    }

    static func build(_ cookies: [Cookie]) -> Data {
        let pages = cookies.map(page)
        var data = Data("cook".utf8)
        data += be32(UInt32(pages.count))
        for page in pages { data += be32(UInt32(page.count)) }
        for page in pages { data += page }
        return data
    }

    private static func page(_ cookie: Cookie) -> Data {
        let strings = [cookie.domain, cookie.name, cookie.path, cookie.value].map { Data($0.utf8) + Data([0]) }
        var offsets: [UInt32] = []
        var cursor: UInt32 = 56   // fixed fields end here
        for string in strings {
            offsets.append(cursor)
            cursor += UInt32(string.count)
        }
        var record = Data()
        record += le32(cursor)                                                     // size
        record += le32(0)                                                          // version
        record += le32((cookie.secure ? 1 : 0) | (cookie.httpOnly ? 4 : 0))       // flags
        record += le32(0)
        for offset in offsets { record += le32(offset) }                           // domain, name, path, value
        record += Data(count: 8)                                                   // end of cookie marker
        let seconds = cookie.expires.map { $0.timeIntervalSinceReferenceDate } ?? 0
        record += leDouble(seconds)                                                // expiry
        record += leDouble(0)                                                      // creation
        for string in strings { record += string }

        var page = be32(0x0000_0100)
        page += le32(1)
        page += le32(16)                                                           // the one cookie starts after this header
        page += le32(0)
        page += record
        return page
    }

    private static func be32(_ value: UInt32) -> Data { Data([UInt8(value >> 24), UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)]) }
    private static func le32(_ value: UInt32) -> Data { Data([UInt8(value & 255), UInt8(value >> 8 & 255), UInt8(value >> 16 & 255), UInt8(value >> 24)]) }
    private static func leDouble(_ value: Double) -> Data {
        let bits = value.bitPattern
        return le32(UInt32(bits & 0xFFFF_FFFF)) + le32(UInt32(bits >> 32))
    }
}

struct SafariCookieReaderTests {

    private let fixture: [SafariFixture.Cookie] = [
        .init(domain: ".github.com", name: "user_session", path: "/", value: "abc123", secure: true, httpOnly: true, expires: future),
        .init(domain: "old.example", name: "stale", path: "/x", value: "gone", expires: past),
        .init(domain: "session.example", name: "sid", path: "/", value: "s1", expires: nil),
    ]

    @Test func readsDomainNamePathValueAndFlags() throws {
        let cookies = try SafariCookieReader.parse(SafariFixture.build(fixture), now: now)
        let session = try #require(cookies.first { $0.name == "user_session" })
        #expect(session.domain == ".github.com")
        #expect(session.path == "/")
        #expect(session.value == "abc123")
        #expect(session.isSecure)
        #expect(session.isHTTPOnly)
        #expect(session.expiresDate.map { abs($0.timeIntervalSince(future)) < 1 } == true)
    }

    @Test func skipsExpiredAndKeepsSessionCookies() throws {
        let cookies = try SafariCookieReader.parse(SafariFixture.build(fixture), now: now)
        #expect(Set(cookies.map(\.name)) == ["user_session", "sid"])
        let sid = try #require(cookies.first { $0.name == "sid" })
        #expect(sid.isSessionOnly)
        #expect(!sid.isSecure)
        #expect(!sid.isHTTPOnly)
    }

    @Test func rejectsAFileThatIsNotACookieFile() {
        #expect(throws: CookieImportError.self) { try SafariCookieReader.parse(Data("nope-not-cookies".utf8), now: now) }
        #expect(throws: CookieImportError.self) { try SafariCookieReader.parse(Data("cook".utf8), now: now) }
    }

    @Test func aTruncatedFileIsReportedNotCrashed() {
        let whole = SafariFixture.build(fixture)
        #expect(throws: CookieImportError.self) { try SafariCookieReader.parse(whole.prefix(whole.count - 20), now: now) }
    }

    @Test func aMissingFileIsUnreadable() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = BrowserProfile(id: "safari", name: "Safari", cookiesURL: folder.appendingPathComponent("Cookies.binarycookies"))
        #expect(throws: CookieImportError.unreadable("Safari's cookie file could not be read.")) { try SafariCookieReader.read(profile) }
    }
}

// MARK: Chromium

struct ChromiumCookieReaderTests {

    private let secret = Data("a-safe-storage-secret".utf8)

    private func encrypt(_ plain: Data, secret: Data, domainHash: Bool) -> Data {
        let key = ChromiumCookieReader.deriveKey(secret: secret)
        let payload = (domainHash ? Data(repeating: 0xAB, count: 32) : Data()) + plain
        let iv = Data(repeating: 0x20, count: 16)
        var out = Data(count: payload.count + 16)
        var produced = 0
        let capacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inBytes.baseAddress, payload.count, outBytes.baseAddress, capacity, &produced
                        )
                    }
                }
            }
        }
        #expect(status == kCCSuccess)
        return Data("v10".utf8) + out.prefix(produced)
    }

    private func chromeMicros(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) }

    private struct Row {
        var host: String, name: String, plain = "", encrypted = Data(), path = "/"
        var expires: Int64 = 0, secure = 0, httpOnly = 0, sameSite = -1
    }

    private func database(version: Int, rows: [Row]) throws -> (folder: URL, cookies: URL) {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent("Cookies")
        let inserts = rows.map {
            """
            INSERT INTO cookies VALUES ('\($0.host)', '\($0.name)', '\($0.plain)', X'\(hex($0.encrypted))', '\($0.path)', \($0.expires), \($0.secure), \($0.httpOnly), \($0.sameSite))
            """
        }
        try makeDatabase(at: url, [
            "CREATE TABLE meta (key TEXT UNIQUE, value TEXT)",
            "INSERT INTO meta VALUES ('version', '\(version)')",
            "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER)",
        ] + inserts)
        return (folder, url)
    }

    @Test func decryptsAndStripsTheDomainHashFromVersion24() throws {
        let rows = [
            Row(host: ".github.com", name: "user_session", encrypted: encrypt(Data("tok-24".utf8), secret: secret, domainHash: true),
                expires: chromeMicros(future), secure: 1, httpOnly: 1, sameSite: 1),
            Row(host: "plain.example", name: "plain", plain: "visible", expires: chromeMicros(future)),
            Row(host: "session.example", name: "sid", encrypted: encrypt(Data("s-1".utf8), secret: secret, domainHash: true), sameSite: 2),
            Row(host: "old.example", name: "stale", encrypted: encrypt(Data("x".utf8), secret: secret, domainHash: true), expires: chromeMicros(past)),
        ]
        let (folder, url) = try database(version: 24, rows: rows)
        defer { try? FileManager.default.removeItem(at: folder) }

        let cookies = try ChromiumCookieReader.read(cookiesURL: url, secret: secret, now: now)
        #expect(Set(cookies.map(\.name)) == ["user_session", "plain", "sid"])   // the expired one is skipped

        let session = try #require(cookies.first { $0.name == "user_session" })
        #expect(session.value == "tok-24")
        #expect(session.domain == ".github.com")
        #expect(session.isSecure)
        #expect(session.isHTTPOnly)
        #expect(session.sameSitePolicy == .sameSiteLax)
        #expect(session.expiresDate.map { abs($0.timeIntervalSince(future)) < 1 } == true)

        #expect(try #require(cookies.first { $0.name == "plain" }).value == "visible")
        let sid = try #require(cookies.first { $0.name == "sid" })
        #expect(sid.value == "s-1")
        #expect(sid.isSessionOnly)
        #expect(sid.sameSitePolicy == .sameSiteStrict)
    }

    @Test func versionsBelow24HaveNoDomainHash() throws {
        let row = Row(host: "a.example", name: "n", encrypted: encrypt(Data("tok-23".utf8), secret: secret, domainHash: false), expires: chromeMicros(future))
        let (folder, url) = try database(version: 23, rows: [row])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try ChromiumCookieReader.read(cookiesURL: url, secret: secret, now: now).first?.value == "tok-23")
    }

    @Test func aWrongSecretRefusesTheWholeImport() throws {
        let wrong = Data("not-the-secret".utf8)
        let rows = (0..<4).map {
            Row(host: "a\($0).example", name: "n\($0)", encrypted: encrypt(Data("v\($0)".utf8), secret: wrong, domainHash: true), expires: chromeMicros(future))
        }
        let (folder, url) = try database(version: 24, rows: rows)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: CookieImportError.unreadable("Chromium decryption failed")) {
            try ChromiumCookieReader.read(cookiesURL: url, secret: secret, now: now)
        }
    }

    @Test func aFewUndecryptableRowsDoNotSpoilTheRest() throws {
        let wrong = Data("not-the-secret".utf8)
        let rows = [
            Row(host: "a.example", name: "good1", encrypted: encrypt(Data("1".utf8), secret: secret, domainHash: true), expires: chromeMicros(future)),
            Row(host: "b.example", name: "good2", encrypted: encrypt(Data("2".utf8), secret: secret, domainHash: true), expires: chromeMicros(future)),
            Row(host: "c.example", name: "bad", encrypted: encrypt(Data("3".utf8), secret: wrong, domainHash: true), expires: chromeMicros(future)),
        ]
        let (folder, url) = try database(version: 24, rows: rows)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(Set(try ChromiumCookieReader.read(cookiesURL: url, secret: secret, now: now).map(\.name)) == ["good1", "good2"])
    }

    @Test func theSourceDatabaseIsNeverModified() throws {
        let row = Row(host: "a.example", name: "n", plain: "v", expires: chromeMicros(future))
        let (folder, url) = try database(version: 24, rows: [row])
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: url)
        _ = try ChromiumCookieReader.read(cookiesURL: url, secret: secret, now: now)
        #expect(try Data(contentsOf: url) == before)
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
    }

    @Test func aFileThatIsNotADatabaseIsUnreadable() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Cookies")
        try write("this is not sqlite at all, not even close, not at all", to: url)
        #expect(throws: CookieImportError.self) { try ChromiumCookieReader.read(cookiesURL: url, secret: secret, now: now) }
    }

    @Test func keyDerivationMatchesChromium() {
        // Chromium on macOS: PBKDF2-HMAC-SHA1(password, "saltysalt", 1003, 16). The expected value comes from
        // an independent implementation: python3 -c "import hashlib; print(hashlib.pbkdf2_hmac('sha1', b'peanuts', b'saltysalt', 1003, 16).hex())"
        #expect(hex(ChromiumCookieReader.deriveKey(secret: Data("peanuts".utf8))) == "d9a09d499b4e1b7461f28e67972c6dbd")
    }

    @Test func otherFormatsAreNotDecrypted() {
        let key = ChromiumCookieReader.deriveKey(secret: secret)
        #expect(ChromiumCookieReader.decrypt(Data("v20".utf8) + Data(count: 32), key: key, stripsDomainHash: false) == nil)
        #expect(ChromiumCookieReader.decrypt(Data("v10".utf8) + Data(count: 7), key: key, stripsDomainHash: false) == nil)
    }

    @Test func chromeEpochConvertsToADate() {
        #expect(ChromiumCookieReader.expiryDate(chromeMicroseconds: 0) == nil)
        let date = ChromiumCookieReader.expiryDate(chromeMicroseconds: 13_300_000_000_000_000)
        #expect(date.map { abs($0.timeIntervalSince1970 - (13_300_000_000 - 11_644_473_600)) < 1 } == true)
    }
}

// MARK: Firefox

struct FirefoxCookieReaderTests {

    @Test func readsCookiesAndNormalisesExpiry() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cookies.sqlite")
        let seconds = Int64(future.timeIntervalSince1970)
        try makeDatabase(at: url, [
            "CREATE TABLE moz_cookies (host TEXT, name TEXT, value TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER, sameSite INTEGER)",
            "INSERT INTO moz_cookies VALUES ('.github.com', 'user_session', 'tok', '/', \(seconds), 1, 1, 1)",
            "INSERT INTO moz_cookies VALUES ('ms.example', 'in_ms', 'v', '/', \(seconds * 1000), 0, 0, 2)",
            "INSERT INTO moz_cookies VALUES ('old.example', 'stale', 'v', '/', \(Int64(past.timeIntervalSince1970)), 0, 0, 0)",
            "INSERT INTO moz_cookies VALUES ('session.example', 'sid', 'v', '/', 0, 0, 0, 0)",
        ])
        let cookies = try FirefoxCookieReader.read(cookiesURL: url, now: now)
        #expect(Set(cookies.map(\.name)) == ["user_session", "in_ms", "sid"])

        let session = try #require(cookies.first { $0.name == "user_session" })
        #expect(session.value == "tok")
        #expect(session.isSecure)
        #expect(session.isHTTPOnly)
        #expect(session.sameSitePolicy == .sameSiteLax)
        #expect(session.expiresDate.map { abs($0.timeIntervalSince(future)) < 1 } == true)

        // A millisecond expiry lands on the same instant as the seconds one.
        let inMs = try #require(cookies.first { $0.name == "in_ms" })
        #expect(inMs.expiresDate.map { abs($0.timeIntervalSince(future)) < 1 } == true)
        #expect(inMs.sameSitePolicy == .sameSiteStrict)
        #expect(try #require(cookies.first { $0.name == "sid" }).isSessionOnly)
    }

    @Test func aDatabaseWithoutTheTableIsUnreadable() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cookies.sqlite")
        try makeDatabase(at: url, ["CREATE TABLE other (a TEXT)"])
        #expect(throws: CookieImportError.self) { try FirefoxCookieReader.read(cookiesURL: url, now: now) }
    }
}

// MARK: Profiles

struct BrowserProfileTests {

    @Test func chromiumProfilesComeFromLocalState() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("""
            {"profile": {"info_cache": {
              "Profile 10": {"name": "Ten", "user_name": ""},
              "Profile 2": {"name": "Client", "user_name": "me@client.com"},
              "Default": {"name": "Personal", "user_name": "me@home.com"},
              "Profile 3": {"name": "No cookies", "user_name": ""},
              "Legacy": {"name": "Old layout", "user_name": ""}
            }}}
            """, to: root.appendingPathComponent("Local State"))
        try touch(root.appendingPathComponent("Default/Network/Cookies"))
        try touch(root.appendingPathComponent("Profile 2/Network/Cookies"))
        try touch(root.appendingPathComponent("Profile 10/Network/Cookies"))
        try touch(root.appendingPathComponent("Legacy/Cookies"))                 // before Chromium moved it to Network/
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Profile 3"), withIntermediateDirectories: true)

        let profiles = try BrowserProfile.profiles(for: .chrome, root: root, home: root)
        #expect(profiles.map(\.id) == ["Default", "Legacy", "Profile 2", "Profile 10"])   // Default first, the rest in natural order
        #expect(profiles.map(\.name) == ["Personal (me@home.com)", "Old layout", "Client (me@client.com)", "Ten"])
        #expect(profiles[0].cookiesURL.path.hasSuffix("Default/Network/Cookies"))
        #expect(profiles[1].cookiesURL.path.hasSuffix("Legacy/Cookies"))
    }

    @Test func aChromiumBrowserWithoutLocalStateHasNoProfiles() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try BrowserProfile.profiles(for: .brave, root: root, home: root).isEmpty)
    }

    @Test func aDamagedLocalStateIsReported() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("{ not json", to: root.appendingPathComponent("Local State"))
        #expect(throws: CookieImportError.self) { try BrowserProfile.profiles(for: .edge, root: root, home: root) }
    }

    @Test func firefoxProfilesComeFromProfilesIni() throws {
        let root = try makeFolder()
        let elsewhere = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: elsewhere) }
        try write("""
            [Install4F96D1932A9F858E]
            Default=Profiles/abc.default-release

            [Profile1]
            Name=work
            IsRelative=0
            Path=\(elsewhere.path)

            [Profile0]
            Name=default-release
            IsRelative=1
            Path=Profiles/abc.default-release
            Default=1

            [Profile2]
            Name=empty
            IsRelative=1
            Path=Profiles/nothing

            [General]
            StartWithLastProfile=1
            """, to: root.appendingPathComponent("profiles.ini"))
        try touch(root.appendingPathComponent("Profiles/abc.default-release/cookies.sqlite"))
        try touch(elsewhere.appendingPathComponent("cookies.sqlite"))

        let profiles = try BrowserProfile.profiles(for: .firefox, root: root, home: root)
        #expect(Set(profiles.map(\.name)) == ["default-release", "work"])   // [Install…] and [General] are not profiles, "empty" has no cookies
        #expect(profiles.first { $0.name == "default-release" }?.cookiesURL.path.hasSuffix("Profiles/abc.default-release/cookies.sqlite") == true)
        #expect(profiles.first { $0.name == "work" }?.cookiesURL.path == elsewhere.appendingPathComponent("cookies.sqlite").path)
    }

    @Test func safariIsOneProfileWithFallbackToTheOlderLocation() throws {
        let home = try makeFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        let container = ImportableBrowser.safari.dataRoot(home: home)

        // Neither file exists: the container path (the reader then reports why it can't read it).
        var profiles = try BrowserProfile.profiles(for: .safari, root: container, home: home)
        #expect(profiles.map(\.id) == ["safari"])
        #expect(profiles[0].cookiesURL == container.appendingPathComponent("Cookies.binarycookies"))

        // Only the older location exists.
        try touch(home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"))
        profiles = try BrowserProfile.profiles(for: .safari, root: container, home: home)
        #expect(profiles[0].cookiesURL == home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"))

        // The container file wins when both exist.
        try touch(container.appendingPathComponent("Cookies.binarycookies"))
        profiles = try BrowserProfile.profiles(for: .safari, root: container, home: home)
        #expect(profiles[0].cookiesURL == container.appendingPathComponent("Cookies.binarycookies"))
    }
}

struct ImportableBrowserTests {

    @Test func theChromiumFamilyHasKeychainDetails() {
        for browser in ImportableBrowser.allCases {
            #expect((browser.keychainService != nil) == browser.isChromium)
            #expect((browser.keychainAccount != nil) == browser.isChromium)
        }
        #expect(ImportableBrowser.chrome.keychainService == "Chrome Safe Storage")
        #expect(ImportableBrowser.edge.keychainAccount == "Microsoft Edge")
    }

    @Test func dataRootsLiveWhereEachBrowserKeepsThem() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        #expect(ImportableBrowser.chrome.dataRoot(home: home).path == "/Users/test/Library/Application Support/Google/Chrome")
        #expect(ImportableBrowser.arc.dataRoot(home: home).path == "/Users/test/Library/Application Support/Arc/User Data")
        #expect(ImportableBrowser.firefox.dataRoot(home: home).path == "/Users/test/Library/Application Support/Firefox")
        #expect(ImportableBrowser.safari.dataRoot(home: home).path == "/Users/test/Library/Containers/com.apple.Safari/Data/Library/Cookies")
    }

    @Test func orderFollowsAllCases() {
        #expect(ImportableBrowser.allCases == [.safari, .chrome, .arc, .brave, .edge, .chromium, .firefox])
    }
}

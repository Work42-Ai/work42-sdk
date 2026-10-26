// ChromiumCookieReader.swift - cookies from Chrome, Arc, Brave, Edge and Chromium (WOR-417).
//
// A Chromium browser keeps cookies in a SQLite file and encrypts each value with AES-128-CBC. The key is derived
// (PBKDF2-HMAC-SHA1, salt "saltysalt", 1003 rounds) from a "Safe Storage" secret in the macOS Keychain, which the
// browser put there and the user must allow us to read.

import CommonCrypto
import Foundation
import Security

public nonisolated enum ChromiumCookieReader {

    /// Every non-expired cookie of `profile`. Asks for the browser's Keychain secret (the system shows a prompt).
    public static func read(_ profile: BrowserProfile, browser: ImportableBrowser) throws -> [HTTPCookie] {
        try read(cookiesURL: profile.cookiesURL, secret: keychainSecret(for: browser), browser: browser.displayName, now: Date())
    }

    /// The reader without the Keychain: `secret` is the browser's Safe Storage password. Tests call this directly.
    static func read(cookiesURL: URL, secret: Data, browser: String = "Chromium", now: Date) throws -> [HTTPCookie] {
        let copy = try DatabaseCopy(copying: cookiesURL, browser: browser)
        defer { copy.cleanup() }
        let database = try SQLiteDatabase(path: copy.url.path)

        var version = 0
        try database.rows("SELECT value FROM meta WHERE key='version'") { version = Int($0.text(0)) ?? 0 }
        // From version 24 the plaintext starts with a SHA-256 of the cookie's domain.
        let stripsDomainHash = version >= 24
        let key = deriveKey(secret: secret)

        var cookies: [HTTPCookie] = []
        var encryptedRows = 0
        var failedRows = 0
        try database.rows("""
            SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite FROM cookies
            """) { row in
            let encrypted = row.data(3)
            var value = row.text(2)
            if !encrypted.isEmpty {
                encryptedRows += 1
                guard let plain = decrypt(encrypted, key: key, stripsDomainHash: stripsDomainHash),
                      let text = String(data: plain, encoding: .utf8) else {
                    failedRows += 1
                    return
                }
                value = text
            }
            let expires = expiryDate(chromeMicroseconds: row.int64(5))
            guard !ImportedCookie.isExpired(expires, now: now),
                  let cookie = ImportedCookie.make(
                    domain: row.text(0), name: row.text(1), value: value, path: row.text(4), expires: expires,
                    secure: row.int64(6) != 0, httpOnly: row.int64(7) != 0, sameSite: sameSite(row.int64(8))
                  ) else { return }
            cookies.append(cookie)
        }
        // A wrong key decrypts to garbage: refuse the whole import rather than bring in broken cookies.
        if encryptedRows > 0, failedRows * 2 > encryptedRows {
            throw CookieImportError.unreadable("Chromium decryption failed")
        }
        return cookies
    }

    // MARK: Crypto

    /// PBKDF2-HMAC-SHA1(secret, "saltysalt", 1003 rounds) to 16 bytes.
    static func deriveKey(secret: Data) -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: 16)
        let status = key.withUnsafeMutableBytes { keyBytes in
            secret.withUnsafeBytes { secretBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        secretBytes.bindMemory(to: Int8.self).baseAddress, secret.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress, 16
                    )
                }
            }
        }
        return status == kCCSuccess ? key : Data()
    }

    /// `v10`/`v11` + AES-128-CBC (IV: sixteen spaces, PKCS7). Nil for any other format or a bad padding.
    static func decrypt(_ encrypted: Data, key: Data, stripsDomainHash: Bool) -> Data? {
        let prefix = encrypted.prefix(3)
        guard prefix == Data("v10".utf8) || prefix == Data("v11".utf8), key.count == 16 else { return nil }
        let body = encrypted.dropFirst(3)
        guard !body.isEmpty, body.count % kCCBlockSizeAES128 == 0 else { return nil }
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: body.count + kCCBlockSizeAES128)
        var produced = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outBytes in
            body.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inBytes.baseAddress, body.count,
                            outBytes.baseAddress, outputCapacity, &produced
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        let plain = output.prefix(produced)
        if stripsDomainHash {
            guard plain.count >= 32 else { return nil }
            return Data(plain.dropFirst(32))
        }
        return Data(plain)
    }

    // MARK: Keychain

    private static func keychainSecret(for browser: ImportableBrowser) throws -> Data {
        guard let service = browser.keychainService, let account = browser.keychainAccount else {
            throw CookieImportError.unreadable("\(browser.displayName) is not a Chromium browser.")
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data else { throw CookieImportError.unreadable("\(browser.displayName)'s Keychain entry was empty.") }
            return data
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw CookieImportError.keychainDenied
        case errSecItemNotFound:
            throw CookieImportError.unreadable("\(browser.displayName) has no \"\(service)\" entry in the Keychain.")
        case let status:
            throw CookieImportError.unreadable("The Keychain returned error \(status).")
        }
    }

    // MARK: Values

    /// `expires_utc` is microseconds since 1601-01-01; 0 is a session cookie.
    static func expiryDate(chromeMicroseconds: Int64) -> Date? {
        guard chromeMicroseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(chromeMicroseconds) / 1_000_000 - 11_644_473_600)
    }

    /// `samesite`: -1 unspecified, 0 none, 1 lax, 2 strict.
    private static func sameSite(_ value: Int64) -> String? {
        switch value {
        case 1: "lax"
        case 2: "strict"
        default: nil
        }
    }
}

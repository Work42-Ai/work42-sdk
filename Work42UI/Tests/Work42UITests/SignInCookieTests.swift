// SignInCookieTests.swift — a cookie must survive the trip from the Mac's store to the iPad's (WOR-601).
//
// A login cookie is usually Secure, HttpOnly and SameSite. If rebuilding it from its wire form silently dropped any of those, or the
// whole cookie, the iPad would report an import and still be signed out.

import Foundation
import Testing

@testable import Work42UI

@Suite("Sign-in cookies")
struct SignInCookieTests {

    private func session() -> HTTPCookie {
        HTTPCookie(properties: [
            .name: "session", .value: "abc123", .domain: ".linear.app", .path: "/",
            .expires: Date(timeIntervalSinceNow: 3600), .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE",
            .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax,
        ])!
    }

    @Test("a Secure, HttpOnly, SameSite cookie comes back whole")
    func roundTrip() throws {
        let original = session()
        let wire = SignInCookie(original)
        let back = try #require(wire.httpCookie, "a login cookie must not be dropped")
        #expect(back.name == "session" && back.value == "abc123")
        #expect(back.domain == ".linear.app" && back.path == "/")
        #expect(back.isSecure && back.isHTTPOnly)
        #expect(back.sameSitePolicy == original.sameSitePolicy)
        #expect(abs((back.expiresDate?.timeIntervalSince1970 ?? 0) - (original.expiresDate?.timeIntervalSince1970 ?? -1)) < 1)
    }

    @Test("it survives the JSON that crosses the link")
    func throughJSON() throws {
        let export = SignInCookieExport(cookies: [SignInCookie(session()), SignInCookie(name: "pref", value: "1", domain: "linear.app", path: "/")])
        let decoded = try #require(SignInCookieExport.decode(export.encoded()))
        #expect(decoded == export)
        #expect(decoded.cookies.allSatisfy { $0.httpCookie != nil })
    }

    @Test("a session cookie keeps having no expiry, and a cookie with no name or domain is refused")
    func edges() {
        let sessionOnly = SignInCookie(name: "s", value: "v", domain: "x.test", path: "")
        #expect(sessionOnly.httpCookie?.expiresDate == nil)
        #expect(sessionOnly.httpCookie?.path == "/", "an empty path is the root")
        #expect(SignInCookie(name: "", value: "v", domain: "x.test", path: "/").httpCookie == nil)
        #expect(SignInCookie(name: "n", value: "v", domain: "", path: "/").httpCookie == nil)
    }
}

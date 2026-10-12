// BrowserAddressResolver.swift — turns what the user typed in the address field into a URL to load (WOR-113).
//
// Addresses go straight to the page; anything else is a Google search. The rules, in order:
//   1. Trim; empty is nil (no navigation).
//   2. Text with whitespace is a phrase: a search.
//   3. An explicit `http`, `https`, `file` or `work42` URL loads as typed. Any other explicit scheme
//      (`javascript:`, `mailto:`, `data:`, `ftp://`, ...) is nil: it is never run and never sent to Google.
//   4. Otherwise it is an address when the host is `localhost`, an IPv4 literal, a bracketed IPv6 literal, a dotted
//      domain, or a bare host with a port (`devbox:3000`). The port, if present, must be 1...65535.
//      The scheme defaults to http for localhost/loopback and https for everything else.
//   5. Everything else — ordinary words, a bare word like `confluence`, numbers like `3.14`, an email address, a
//      host with a malformed port — is a search.

import Foundation

enum BrowserAddressResolver {

    static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return searchURL(for: text) }

        switch explicitURL(text) {
        case .url(let url): return url
        case .rejected: return nil
        case .none: break
        }
        switch addressURL(text) {
        case .address(let url): return url
        case .search: return searchURL(for: text)
        case .notAnAddress:
            // `javascript:alert(1)`, `mailto:a@b.c`, `tel:123`: a scheme we do not open, not something to search for.
            return hasSchemePrefix(text) ? nil : searchURL(for: text)
        }
    }

    // MARK: Search

    static func searchURL(for phrase: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "q", value: phrase)]
        // URLQueryItem leaves `+` and `=` raw in a value, and Google reads a raw `+` as a space.
        if let query = components.percentEncodedQuery, let split = query.firstIndex(of: "=") {
            let value = query[query.index(after: split)...]
                .replacingOccurrences(of: "+", with: "%2B")
                .replacingOccurrences(of: "=", with: "%3D")
            components.percentEncodedQuery = "q=" + value
        }
        return components.url
    }

    // MARK: Explicit URLs

    private static let supportedSchemes: Set<String> = ["http", "https", "file", "work42"]

    private enum ExplicitResult {
        case url(URL)
        /// An explicit URL we will not load (unsupported scheme, no host, bad port).
        case rejected
        /// Not an explicit URL at all.
        case none
    }

    private static func explicitURL(_ text: String) -> ExplicitResult {
        guard let range = text.range(of: "://"),
              let scheme = schemePrefix(text[..<range.lowerBound]) else { return .none }
        let lowered = scheme.lowercased()
        guard supportedSchemes.contains(lowered), let url = URL(string: text) else { return .rejected }
        if lowered == "http" || lowered == "https" {
            guard let host = url.host, !host.isEmpty else { return .rejected }
            if let port = url.port, !(1...65535).contains(port) { return .rejected }
        }
        return .url(url)
    }

    /// The scheme if `text` is exactly an RFC 3986 scheme (`letter *( letter / digit / "+" / "-" / "." )`).
    private static func schemePrefix(_ text: some StringProtocol) -> String? {
        guard let first = text.first, first.isASCII, first.isLetter else { return nil }
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return nil }
        return String(text)
    }

    private static func hasSchemePrefix(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        return schemePrefix(text[..<colon]) != nil
    }

    // MARK: Addresses without a scheme

    private enum AddressResult {
        case address(URL)
        /// Looks like an address but is not valid (a malformed port): searched, not navigated.
        case search
        case notAnAddress
    }

    private static func addressURL(_ text: String) -> AddressResult {
        // authority = everything up to the path, query or fragment.
        let end = text.firstIndex(where: { "/?#".contains($0) }) ?? text.endIndex
        let authority = String(text[..<end])
        let remainder = String(text[end...])
        guard !authority.isEmpty else { return .notAnAddress }

        let host: String
        var portText: String?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return .notAnAddress }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let after = authority[authority.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return .notAnAddress }
                portText = String(after.dropFirst())
            }
            guard isIPv6(host) else { return .notAnAddress }
        } else {
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return .notAnAddress }
            host = String(parts[0])
            if parts.count == 2 { portText = String(parts[1]) }
        }

        let isBracketed = authority.hasPrefix("[")
        let hostKind = classify(host, bracketed: isBracketed)
        let hasPort = portText != nil

        // A bare single-label host is an address only with a port (`devbox:3000`); a bare word alone is a search.
        guard hostKind != .invalid, hostKind != .bareLabel || hasPort else { return .notAnAddress }

        // `javascript:alert(1)`, `tel:123`, `about:blank` read like `devbox:3000`; a bare label that names a
        // well-known non-web scheme is that scheme, not a host.
        if hostKind == .bareLabel, nonWebSchemes.contains(host.lowercased()) { return .notAnAddress }

        var port: Int?
        if let portText {
            let digitsOnly = !portText.isEmpty && portText.allSatisfy { $0.isASCII && $0.isNumber }
            if hostKind == .bareLabel, !digitsOnly { return .notAnAddress }   // `foo:bar` is a scheme-like word
            guard digitsOnly, let value = Int(portText), (1...65535).contains(value) else { return .search }
            port = value
        }

        var components = URLComponents()
        components.scheme = hostKind == .loopback ? "http" : "https"
        components.host = isBracketed ? "[\(host)]" : host
        components.port = port
        guard var base = components.url?.absoluteString else { return .search }
        base += remainder
        guard let url = URL(string: base) else { return .search }
        return .address(url)
    }

    private static let nonWebSchemes: Set<String> = [
        "javascript", "data", "mailto", "tel", "sms", "about", "blob", "vbscript", "view-source", "chrome",
        "ftp", "ssh", "sftp", "smb", "vnc", "irc", "magnet", "facetime", "itms", "x-apple",
    ]

    private enum HostKind { case loopback, domain, ipv4, ipv6, bareLabel, invalid }

    private static func classify(_ host: String, bracketed: Bool) -> HostKind {
        if bracketed { return host == "::1" ? .loopback : .ipv6 }
        if host.lowercased() == "localhost" { return .loopback }
        if isIPv4(host) { return host.hasPrefix("127.") ? .loopback : .ipv4 }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.allSatisfy(isValidLabel) else { return .invalid }
        if labels.count == 1 { return .bareLabel }
        // The top-level label is never purely numeric (`3.14`, `1.2.3`) and at least two characters (`a.b`).
        guard let tld = labels.last, tld.count >= 2, !tld.allSatisfy(\.isNumber) else { return .invalid }
        return .domain
    }

    private static func isValidLabel(_ label: String) -> Bool {
        guard (1...63).contains(label.count), !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        return label.allSatisfy { $0 == "-" || $0.isLetter || $0.isNumber }
    }

    private static func isIPv4(_ host: String) -> Bool {
        var address = in_addr()
        return host.split(separator: ".", omittingEmptySubsequences: false).count == 4
            && inet_pton(AF_INET, host, &address) == 1
    }

    private static func isIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        return inet_pton(AF_INET6, host, &address) == 1
    }
}

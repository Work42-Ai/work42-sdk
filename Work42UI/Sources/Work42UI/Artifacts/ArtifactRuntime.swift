// ArtifactRuntime.swift - The cross-process contract for per-session artifacts.
//
// Promoted into the SDK (task42-plugin-conversion, s4) from the original
// Flow42Core/Common/ArtifactRuntime.swift, which stays in Flow42Core as a
// thin re-export so nothing in the app changes its import — see that file.
// This is now the ONE implementation both the app and any hot-loaded plugin
// widget link: a plugin widget can only `import Work42PluginKit`
// (transitively `Work42UI`), never `Work42Core` — Work42UI.framework +
// Work42PluginKit.framework are the only two frameworks a plugin's build
// links (`work42 widget build`). Promoting this lets a plugin's spec widget
// resolve `[[artifact:id]]` embeds and self-register without any app-side
// help, using its own `SessionServices.sessionId` (s3).
//
// The artifact system is served by ONE app-hosted HTTP server
// (`ArtifactServer`) but is reached by THREE separate processes that never
// link against each other (the hard repo rule: CLIs and the app talk only
// through the filesystem) — now FOUR, counting a hot-loaded plugin widget:
//
//   * the Work42 app    — runs the server, binds the port, mints the secret
//   * the `work42` CLI  — `work42 artifact url <id>` prints the loadable URL,
//                          and registers the session→dir mapping on `set`
//   * the gallery widget — loads the URL the app already knows in-process
//   * a plugin widget    — resolves `[[artifact:id]]` embeds via this SDK type
//
// This file is the single source of truth those four agree on. It owns:
//
//   1. The machine-global runtime descriptor at
//      `~/.work42/artifacts/runtime.json`
//      = `{ "port": Int, "secret": "<hex>" }`, written `0600`. The server
//      writes it on `start()`; the CLI reads it to build a URL. Its absence
//      means "the server is not running".
//   2. A deterministic, unguessable per-session path token derived from the
//      machine secret + the session id, so the server and the CLI compute
//      the same token without ever exchanging it.
//   3. A session-id → session-directory registry under
//      `~/.work42/artifacts/sessions/<id>.json`
//      = `{ "dir": "<sessionDir>" }`, so the server can locate a session's
//      artifacts dir from just the id in the request path. The CLI (and/or
//      the widget) `register`s; the server `directory(forSessionId:)` reads.
//
// URL shape (generalised from the old canvas URL):
//
//     http://127.0.0.1:<port>/<sessionId>-<token>/<artifactId>/
//
// `url(sessionId:artifactId:)` produces this; the server splits on the
// LAST '-' in the first segment to recover `sessionId` and `token`, then
// splits the remainder on the FIRST '/' to recover `artifactId`.
//
// Everything here is pure file I/O — `nonisolated`, no `@MainActor`, no
// shared mutable state — so it is safe to call from the server's off-main
// connection queues, the CLI process, a plugin widget's synchronous
// resolver closure, and the app's main actor alike.

import CryptoKit
import Foundation

/// File-backed contract shared by the artifact server, the `work42` CLI, the
/// gallery widget, and any hot-loaded plugin widget. Stateless: every helper
/// derives its paths from `~/.work42/artifacts/` and reads/writes JSON on
/// demand.
public nonisolated enum ArtifactRuntime {

    // MARK: - Layout

    /// `~/.work42/` — reproduced inline (NOT `Work42Core.Work42Paths.root()`)
    /// because Work42UI is a standalone SDK package a plugin widget links —
    /// it must not depend on Work42Core, which plugins never link at all.
    /// Same reproduction policy this codebase already uses for cross-target
    /// primitives (e.g. `Work42DB.StorageValue`, "a verbatim copy... does NOT
    /// depend on [the original], so it is reproduced here").
    private static func work42Root() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".work42")
    }

    /// `~/.work42/artifacts/` — the machine-global artifact runtime dir.
    /// Mirror of `ArtifactCommand.runtimeDirName` (Sources/work42/).
    public static func runtimeDir() -> String {
        (work42Root() as NSString).appendingPathComponent("artifacts")
    }

    /// `~/.work42/artifacts/runtime.json` — the bound-port + secret
    /// descriptor.
    public static func runtimeFilePath() -> String {
        (runtimeDir() as NSString).appendingPathComponent("runtime.json")
    }

    /// `~/.work42/artifacts/sessions/` — the session-id → directory
    /// registry.
    public static func sessionsDir() -> String {
        (runtimeDir() as NSString).appendingPathComponent("sessions")
    }

    /// `~/.work42/artifacts/sessions/<sessionId>.json`.
    public static func sessionFilePath(sessionId: String) -> String {
        (sessionsDir() as NSString)
            .appendingPathComponent("\(sessionId).json")
    }

    // MARK: - Runtime descriptor

    /// The bound-port + machine-secret descriptor. `secret` is a random
    /// hex string the server mints once per `start()`; the per-session path
    /// token is derived from it via ``token(secret:sessionId:)``.
    public struct Runtime: Codable, Sendable, Equatable {
        /// The loopback port the `ArtifactServer`'s `NWListener` bound to.
        public let port: Int
        /// The machine-global secret used to derive per-session tokens.
        public let secret: String

        public init(port: Int, secret: String) {
            self.port = port
            self.secret = secret
        }
    }

    /// Read the runtime descriptor, or `nil` if the file is absent or
    /// unreadable (the canonical "server not running" signal).
    public static func readRuntime() -> Runtime? {
        let path = runtimeFilePath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return nil }
        return try? JSONDecoder().decode(Runtime.self, from: data)
    }

    /// Atomically write the runtime descriptor with `0600` perms (owner
    /// read/write only — the secret never leaks to other users). Creates
    /// `~/.work42/artifacts/` if missing.
    public static func writeRuntime(_ runtime: Runtime) throws {
        try FileManager.default.createDirectory(
            atPath: runtimeDir(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(runtime)
        let dest = runtimeFilePath()
        let tmp = dest + ".tmp.\(getpid())"
        try data.write(to: URL(fileURLWithPath: tmp))
        // Lock down to owner-only BEFORE it lands at the canonical path.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: tmp
        )
        if rename(tmp, dest) != 0 {
            let code = errno
            try? FileManager.default.removeItem(atPath: tmp)
            throw ArtifactRuntimeError.writeFailed(
                path: dest, reason: String(cString: strerror(code))
            )
        }
        // Re-assert perms on the final path too (rename preserves them, but
        // be defensive in case the dest pre-existed with looser perms).
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: dest
        )
    }

    /// Remove the runtime descriptor (server shutdown). Best-effort: a
    /// missing file is treated as already-clear and does not throw.
    public static func clearRuntime() {
        try? FileManager.default.removeItem(atPath: runtimeFilePath())
    }

    // MARK: - Per-session token

    /// Deterministic, unguessable, URL-safe per-session path token.
    ///
    /// `token(secret:sessionId:)` is `hex(SHA256("<secret>:<sessionId>"))`
    /// truncated to 20 hex chars (80 bits) — same inputs always produce the
    /// same token, so the server and the CLI agree without exchanging it,
    /// yet a process that doesn't know `secret` cannot forge it. The output
    /// is `[0-9a-f]{20}`, safe to drop straight into a URL path segment.
    public static func token(secret: String, sessionId: String) -> String {
        let key = "\(secret):\(sessionId)"
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(20))
    }

    // MARK: - Loadable URL

    /// The loadable artifact URL for a session + artifact id:
    /// `http://127.0.0.1:<port>/<sessionId>-<token>/<artifactId>/`.
    ///
    /// Returns `nil` when the runtime descriptor is absent (server not
    /// running) — the CLI surfaces that as "the artifact server isn't up
    /// yet".
    ///
    /// The server splits the first path segment on the LAST `-` to recover
    /// `sessionId` and `token`, then splits the remainder on the first `/`
    /// to recover `artifactId`. The CLI and app both use this function to
    /// build the loadable URL, so they agree by construction. Synchronous —
    /// a plugin widget's `artifactURLResolver` (a plain `(String) -> URL?`
    /// closure) can call this directly.
    public static func url(sessionId: String, artifactId: String) -> URL? {
        guard let runtime = readRuntime() else { return nil }
        let tok = token(secret: runtime.secret, sessionId: sessionId)
        return URL(
            string: "http://127.0.0.1:\(runtime.port)/\(sessionId)-\(tok)/\(artifactId)/"
        )
    }

    // MARK: - Session registry

    private struct SessionRecord: Codable, Sendable, Equatable {
        let dir: String
    }

    /// Register a session's on-disk directory so the server can resolve the
    /// session's artifacts dir from just the id in a request path. Writes
    /// `~/.work42/artifacts/sessions/<sessionId>.json` = `{ "dir": "<dir>" }`,
    /// creating the registry dir if missing. Idempotent: re-registering the
    /// same id overwrites the record.
    public static func register(sessionId: String, directory: String) throws {
        try FileManager.default.createDirectory(
            atPath: sessionsDir(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(SessionRecord(dir: directory))
        let dest = sessionFilePath(sessionId: sessionId)
        let tmp = dest + ".tmp.\(getpid())"
        try data.write(to: URL(fileURLWithPath: tmp))
        if rename(tmp, dest) != 0 {
            let code = errno
            try? FileManager.default.removeItem(atPath: tmp)
            throw ArtifactRuntimeError.writeFailed(
                path: dest, reason: String(cString: strerror(code))
            )
        }
    }

    /// The registered session directory for `sessionId`, or `nil` if the
    /// session was never registered. The server maps this through
    /// `Artifact.artifactDir(id:sessionDirectory:)` to locate the artifact
    /// dir for a specific artifact id.
    public static func directory(forSessionId sessionId: String) -> String? {
        let path = sessionFilePath(sessionId: sessionId)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let record = try? JSONDecoder().decode(SessionRecord.self, from: data)
        else { return nil }
        return record.dir
    }

    /// Remove a session's registry record (best-effort; a missing record is
    /// already-clear).
    public static func unregister(sessionId: String) {
        try? FileManager.default.removeItem(
            atPath: sessionFilePath(sessionId: sessionId)
        )
    }

    // MARK: - Errors

    public enum ArtifactRuntimeError: Error, CustomStringConvertible, Equatable {
        case writeFailed(path: String, reason: String)

        public var description: String {
            switch self {
            case let .writeFailed(path, reason):
                return "Failed to write artifact runtime file \(path): \(reason). "
                    + "Suggestion: check ~/.work42/artifacts/ is writable."
            }
        }
    }
}

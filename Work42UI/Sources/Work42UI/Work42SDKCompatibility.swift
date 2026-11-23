import Foundation

/// The public Work42 SDK release, and the one compatibility rule built on it.
///
/// There is a single version: the SDK's semantic version. A plugin records the SDK it was built with as
/// `sdk_version` (the build writes it; authors never edit it), and the host accepts the plugin when
/// `accepts(pluginSDK:)` says so: the same major version, with the host at the plugin's version or newer.
/// A minor or patch release only adds to the public API (CI diffs the API and loads previously built plugins
/// to hold that), so a plugin keeps loading across its whole major line. A breaking change is a new major
/// version, with a migration note in `CHANGELOG.md`.
///
/// The host, CLI, loaders, templates, and release packages all read these values rather than keeping their
/// own mirrors.
public enum Work42SDKCompatibility {
    nonisolated public static let version = "3.1.0"

    /// What the version-probe symbols (`work42_widget_sdk_version`, `work42_plugin_sdk_version`) return in
    /// every 3.x SDK. It only tells the host the dylib answers the probe; compatibility is decided from the
    /// manifest's `sdk_version` with `accepts(pluginSDK:)`, never from this number.
    nonisolated public static let versionProbeValue: Int32 = 3

    /// Whether this host can run a plugin built with `pluginSDK` (its manifest's `sdk_version`).
    nonisolated public static func accepts(pluginSDK: String) -> Bool {
        accepts(pluginSDK: pluginSDK, hostSDK: version)
    }

    /// Whether a host at `hostSDK` can run a plugin built with `pluginSDK`: the same major version, and the
    /// host's minor and patch at or above the plugin's. Either string that is not `MAJOR.MINOR.PATCH` (a
    /// pre-release or build suffix such as `-beta.1` is ignored) is never accepted, which also rejects the
    /// integer ABI generations that older manifests recorded.
    nonisolated public static func accepts(pluginSDK: String, hostSDK: String) -> Bool {
        guard let plugin = components(pluginSDK), let host = components(hostSDK),
              plugin.major == host.major else { return false }
        return (host.minor, host.patch) >= (plugin.minor, plugin.patch)
    }

    /// The major version of `version`, or nil when it is not `MAJOR.MINOR.PATCH`. Lets a caller tell a plugin
    /// built for an older major (rebuild it) from one built for a newer SDK (update Work42).
    nonisolated public static func requiredMajor(_ version: String) -> Int? {
        components(version)?.major
    }

    nonisolated private static func components(_ value: String) -> (major: Int, minor: Int, patch: Int)? {
        // `MAJOR.MINOR.PATCH`, then an optional `-pre-release` or `+build` suffix that must not be empty.
        let split = value.trimmingCharacters(in: .whitespaces)
            .split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: { $0 == "-" || $0 == "+" })
        guard let core = split.first, split.count == 1 || split[1].isEmpty == false else { return nil }
        let pieces = core.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }),
              let major = Int(pieces[0]), let minor = Int(pieces[1]), let patch = Int(pieces[2])
        else { return nil }
        return (major, minor, patch)
    }
}

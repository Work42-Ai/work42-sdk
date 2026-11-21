// The compat fixture's session hook (WOR-856); frozen with the widget, see Widget.swift.

import Foundation
import Work42PluginKit

final class CompatHooks: Work42SessionHooks {
    func onCreate(_ context: SessionCreateContext) async throws {
        try await context.storage.set(key: "hook-ran", value: .string(context.sessionId))
    }
}

@_cdecl("work42_plugin_sdk_version")
public func work42_plugin_sdk_version() -> Int32 { Work42SDKCompatibility.versionProbeValue }

@_cdecl("work42_plugin_main")
public func work42_plugin_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated { result = PluginEntryPoint.register(CompatHooks()) }
    return result
}

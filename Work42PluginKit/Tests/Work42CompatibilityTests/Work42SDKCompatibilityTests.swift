import Testing
import Work42PluginKit
import Work42UI

@Suite("Work42 SDK compatibility")
struct Work42SDKCompatibilityTests {
    @Test("the release is canonical and the probe answers 3")
    func canonicalCompatibility() {
        #expect(Work42SDKCompatibility.version == "3.1.0")
        #expect(WidgetSDK.version == Work42SDKCompatibility.version)
        #expect(Work42SDKCompatibility.versionProbeValue == 3)
        #expect(Work42SDKCompatibility.requiredMajor(Work42SDKCompatibility.version) == 3)
    }

    @Test("this host accepts a plugin built with its own release")
    func hostAcceptsItsOwnVersion() {
        #expect(Work42SDKCompatibility.accepts(pluginSDK: Work42SDKCompatibility.version))
    }

    /// Plugin SDK, host SDK, and whether the host accepts the plugin: the same major, host at or above the plugin.
    @Test("accepts follows the same-major, host-at-or-above rule", arguments: [
        ("3.0.0", "3.0.0", true),
        ("3.0.1", "3.0.0", false),
        ("3.0.0", "3.0.1", true),
        ("3.0.1", "3.2.0", true),
        ("3.2.0", "3.2.0", true),
        ("3.1.0", "3.0.0", false),
        ("3.1.5", "3.2.0", true),
        ("3.2.1", "3.2.0", false),
        ("3.9.9", "3.10.0", true),
        ("2.16.0", "3.0.0", false),
        ("4.0.0", "3.9.9", false),
        ("3.0.0", "4.0.0", false),
        ("3.0.0-beta.1", "3.0.0", true),
        ("3.0.0+build.7", "3.0.0", true),
        ("3.1.0-rc.1", "3.0.0", false),
    ])
    func acceptsRule(plugin: String, host: String, expected: Bool) {
        #expect(Work42SDKCompatibility.accepts(pluginSDK: plugin, hostSDK: host) == expected)
    }

    /// A manifest value that is not `MAJOR.MINOR.PATCH` is never accepted. That includes the integer ABI
    /// generation older manifests recorded in `sdk_version`.
    @Test("anything that is not MAJOR.MINOR.PATCH is rejected", arguments: [
        "", " ", "x", "17", "3", "3.0", "3.0.0.0", "3..0", "3.0.", ".3.0", "3.a.0", "-3.0.0", "3.0.0-", "v3.0.0",
        "3.0.-1", "99999999999999999999.0.0",
    ])
    func rejectsMalformed(value: String) {
        #expect(Work42SDKCompatibility.accepts(pluginSDK: value, hostSDK: "3.0.0") == false)
        #expect(Work42SDKCompatibility.accepts(pluginSDK: "3.0.0", hostSDK: value) == false)
        #expect(Work42SDKCompatibility.requiredMajor(value) == nil)
    }

    @Test("requiredMajor reads the major of a well-formed version")
    func requiredMajorOfValidVersions() {
        #expect(Work42SDKCompatibility.requiredMajor("2.16.0") == 2)
        #expect(Work42SDKCompatibility.requiredMajor("3.0.0-beta.1") == 3)
        #expect(Work42SDKCompatibility.requiredMajor(" 12.4.9 ") == 12)
    }

    @Test("the deprecated probe shim still reports the same value")
    func deprecatedShim() {
        // Expected deprecation warning: this is the test of the shim itself.
        #expect(WidgetSDK.abiVersion == Work42SDKCompatibility.versionProbeValue)
    }
}

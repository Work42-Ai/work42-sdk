import Testing
import Work42PluginKit
import Work42UI

@Suite("Work42 SDK compatibility")
struct Work42SDKCompatibilityTests {
    @Test("release and ABI are canonical")
    func canonicalCompatibility() {
        #expect(Work42SDKCompatibility.version == "2.8.0")
        #expect(Work42SDKCompatibility.abiGeneration == 13)
        #expect(WidgetSDK.version == Work42SDKCompatibility.version)
        #expect(WidgetSDK.abiVersion == Work42SDKCompatibility.abiGeneration)
    }
}

import Testing

@testable import Work42PluginKit

@Suite("Widget pill accessory shell")
struct WidgetPillAccessoryShellTests {
    @Test("meeting accessory geometry is fixed across states")
    func fixedGeometry() {
        #expect(WidgetPillAccessoryMetrics.width == 412)
        #expect(WidgetPillAccessoryMetrics.height == 108)
        #expect(WidgetPillAccessoryMetrics.iconSize == 36)
        #expect(WidgetPillAccessoryMetrics.actionHeight == 32)
        #expect(WidgetPillAccessoryMetrics.progressHeight == 3)
    }
}

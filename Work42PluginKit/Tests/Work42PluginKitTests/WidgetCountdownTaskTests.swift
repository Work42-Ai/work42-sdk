import Testing

@testable import Work42PluginKit

@Suite("Widget countdown task")
@MainActor
struct WidgetCountdownTaskTests {
    @Test("expiration action can cancel owner without cancelling itself")
    func expirationReleasesHandleBeforeAction() async {
        let countdown = WidgetCountdownTask()
        let actionWasCancelled = await withCheckedContinuation { continuation in
            countdown.schedule(after: .milliseconds(1)) {
                countdown.cancel()
                continuation.resume(returning: Task.isCancelled)
            }
        }

        #expect(!actionWasCancelled)
        #expect(!countdown.isScheduled)
    }

    @Test("explicit cancellation suppresses expiration")
    func cancellationSuppressesAction() async throws {
        let countdown = WidgetCountdownTask()
        var fired = false
        countdown.schedule(after: .milliseconds(20)) { fired = true }
        countdown.cancel()

        try await Task.sleep(for: .milliseconds(40))
        #expect(!fired)
        #expect(!countdown.isScheduled)
    }
}

import Foundation

/// Owns one cancellable UI countdown without retaining the expired task while
/// its action runs. This lets a shared completion path call `cancel()` safely.
@MainActor
public final class WidgetCountdownTask {
    private var task: Task<Void, Never>?

    public init() {}

    public var isScheduled: Bool { task != nil }

    public func schedule(
        after delay: Duration,
        action: @escaping @MainActor @Sendable () async -> Void
    ) {
        cancel()
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            task = nil
            await action()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}

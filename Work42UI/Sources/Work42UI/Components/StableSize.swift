// StableSize.swift — Holds a view's frame at the last "settled" size
// during container animations, then jumps to the new size discretely
// once the size has been stable for ~150 ms.
//
// Use it on subviews whose internal layout is expensive (TextKit 2
// editors, long markdown bodies, anything that re-typesets on every
// width change). The parent's ⌘B sidebar toggle / window resize will
// still animate smoothly for the *rest* of the UI; the wrapped view
// just holds its current frame for the animation and snaps to the
// final size at the end.
//
// Implementation parallels `SessionDetailPanel.widgetRow`'s inactive-
// tab pinning, but scoped to a single wrapped subtree.

import SwiftUI

public extension View {
    /// Hold this view's frame at the last "settled" size while its
    /// container is animating, then jump to the new size once the
    /// size stops changing for `debounce` seconds. See
    /// `StableSize.swift` for the full rationale.
    func stableSize(debounce: TimeInterval = 0.15) -> some View {
        modifier(StableSizeModifier(debounce: debounce))
    }
}

public struct StableSizeModifier: ViewModifier {
    let debounce: TimeInterval

    @State private var pinnedSize: CGSize? = nil
    @State private var settleTask: Task<Void, Never>? = nil

    public func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .frame(
                    width: pinnedSize?.width ?? proxy.size.width,
                    height: pinnedSize?.height ?? proxy.size.height
                )
                .onAppear {
                    // Seed once so the first frame doesn't render at
                    // an uninitialized live size (which may itself be
                    // mid-animation if the view appears during one).
                    pinnedSize = proxy.size
                }
                .onChange(of: proxy.size) { _, newSize in
                    // Debounced settle: hold the pinned size until the
                    // container's size has been steady for `debounce`
                    // seconds, then snap to the new size in a
                    // non-animated transaction so SwiftUI doesn't
                    // interpolate the frame change itself.
                    settleTask?.cancel()
                    settleTask = Task { @MainActor in
                        let nanos = UInt64(debounce * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: nanos)
                        guard !Task.isCancelled else { return }
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            pinnedSize = newSize
                        }
                    }
                }
        }
    }
}

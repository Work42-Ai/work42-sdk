// FindBar.swift - The shared in-content find bar, moved into Work42UI.
//
// Moved from Work42App/Common/FindBar.swift to Work42UI
// (browser-widgets-not-extending-from-browser.1) so that BrowserFindBar.swift
// can live in the Work42UI framework. All existing conformers in Work42App
// (SourceEditorFindBackend, DiffFindBackend) continue to work via
// `import Work42UI`.
//
// This is the *actual* find bar the embedded-browser widgets use (the Liquid
// Glass capsule with the X-of-N count and prev/next/close controls), lifted
// verbatim into a reusable component so the file editor, the diff tile, and
// the browser all drive the SAME view through a pluggable `FindBarBackend`.
// It is NOT a lookalike rebuilt from scratch — the glass surface, keyboard
// contract, and layout are exactly what the browser finder shipped.
//
// Keyboard contract:
//   Enter       → backend.findNext()
//   Shift+Enter → backend.findPrevious()   (via onSubmit + isShiftDown)
//   Esc         → backend.closeFind()
//
// Each surface supplies a `FindBarBackend` conformer:
//   • BrowserWidgetModel        (web content, JS-injection find)
//   • SourceEditorFindBackend   (file editor, in-buffer + emphasisManager)
//   • DiffFindBackend           (diff tile, rendered-line search)

import SwiftUI

// MARK: - FindBarBackend

/// The find engine a `FindBar` drives. A tile conforms its model (an
/// `ObservableObject`, so the X-of-N count re-renders on async updates) to
/// this and hands it to `FindBar`. All results are `(current, total)` — a
/// 1-based active-match index and a total match count.
@MainActor
public protocol FindBarBackend: ObservableObject {
    /// The text currently in the field (two-way bound by the bar).
    var findQuery: String { get set }
    /// The 1-based index of the active match (0 when none).
    var findCurrent: Int { get }
    /// The total number of matches for the current query (0 when none).
    var findTotal: Int { get }

    /// Run `findQuery` fresh and update the counts.
    func runFind() async
    /// Advance to the next match, scroll it into view, update the counts.
    func findNext() async
    /// Advance to the previous match, scroll it into view, update the counts.
    func findPrevious() async
    /// Close the bar and clear match highlights.
    func closeFind()
}

// MARK: - FindBar

/// The compact find bar shown as an overlay on a content surface. Binds to a
/// `FindBarBackend` via `@ObservedObject` so count updates from async find
/// operations re-render the X-of-N label without a full host body re-eval.
@MainActor
public struct FindBar<Backend: FindBarBackend>: View {

    @ObservedObject public var backend: Backend

    /// Placeholder text — defaults to the browser's "Find in page…"; the file
    /// editor and diff tile pass a plain "Find".
    public var placeholder: String = "Find in page…"

    /// Tracks whether Shift is held so onSubmit chooses prev vs next.
    @State private var isShiftDown: Bool = false

    /// Drives focus into the text field when the bar opens.
    @FocusState private var isFieldFocused: Bool

    public init(backend: Backend, placeholder: String = "Find in page…") {
        self.backend = backend
        self.placeholder = placeholder
    }

    public var body: some View {
        HStack(spacing: DT.s8) {

            // ── Text field ─────────────────────────────────────────────────
            TextField(placeholder, text: $backend.findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: DT.f12))
                // Fixed width so the bar doesn't reflow as the query grows.
                .frame(width: 170)
                .focused($isFieldFocused)
                .onChange(of: backend.findQuery) { _, _ in
                    Task { await backend.runFind() }
                }
                .onSubmit {
                    if isShiftDown {
                        Task { await backend.findPrevious() }
                    } else {
                        Task { await backend.findNext() }
                    }
                }
                // Esc key: close the find bar. Detected with a background
                // NSEvent monitor so the TextField sees it before the window.
                .background(
                    EscapeKeyCapture {
                        backend.closeFind()
                    }
                )
                // Track Shift state so onSubmit knows which direction to go.
                .background(
                    ShiftKeyTracker(isShiftDown: $isShiftDown)
                )

            // ── X of N count ───────────────────────────────────────────────
            matchCountLabel

            // ── Previous / Next ────────────────────────────────────────────
            Button {
                Task { await backend.findPrevious() }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        backend.findTotal > 0
                            ? AnyShapeStyle(.primary)
                            : AnyShapeStyle(.tertiary)
                    )
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(backend.findTotal == 0)
            .help("Previous match")

            Button {
                Task { await backend.findNext() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        backend.findTotal > 0
                            ? AnyShapeStyle(.primary)
                            : AnyShapeStyle(.tertiary)
                    )
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(backend.findTotal == 0)
            .help("Next match")

            // ── Close ──────────────────────────────────────────────────────
            Button {
                backend.closeFind()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AnyShapeStyle(.secondary))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Find Bar")
        }
        .padding(.horizontal, DT.s12)
        .padding(.vertical, DT.s8)
        .glassCapsuleSurface()
        // Focus the text field when the bar becomes visible.
        .onAppear { isFieldFocused = true }
    }

    // MARK: - Match count label

    /// The count text: empty (no query), "No results", or "X of N".
    private var countText: String {
        if backend.findQuery.isEmpty { return "" }
        return backend.findTotal == 0
            ? "No results"
            : "\(backend.findCurrent) of \(backend.findTotal)"
    }

    private var matchCountLabel: some View {
        // A single Text at a FIXED width so the capsule never changes size —
        // whether it shows a count, "No results", or nothing.
        Text(countText)
            .font(.system(size: DT.f11).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 88, alignment: .trailing)
    }
}

// MARK: - EscapeKeyCapture

/// A zero-size background view that installs a local NSEvent monitor to
/// catch the Escape key while the find bar is focused, invoking `onEscape`
/// before the event reaches the window's key-binding path.
public struct EscapeKeyCapture: NSViewRepresentable {

    public let onEscape: () -> Void

    public init(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(onEscape: onEscape)
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        // nonisolated(unsafe) because deinit is nonisolated in Swift 6 and
        // NSEvent monitor tokens are opaque Any? objects that are not Sendable.
        // The monitor is only read in deinit and written on the main actor,
        // so accesses are effectively serialised in practice.
        nonisolated(unsafe) private var monitor: Any?

        public func install(onEscape: @escaping () -> Void) {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Escape
                    DispatchQueue.main.async { onEscape() }
                    return nil // consume the event
                }
                return event
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

// MARK: - ShiftKeyTracker

/// A zero-size background view that installs a local NSEvent monitor to
/// track Shift-key up/down state, writing into the provided binding so
/// `onSubmit` can choose findNext vs findPrevious.
public struct ShiftKeyTracker: NSViewRepresentable {

    @Binding public var isShiftDown: Bool

    public init(isShiftDown: Binding<Bool>) {
        self._isShiftDown = isShiftDown
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(binding: $isShiftDown)
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        // nonisolated(unsafe) for the same reason as EscapeKeyCapture.Coordinator:
        // deinit is nonisolated in Swift 6 and Any? is not Sendable.
        nonisolated(unsafe) private var monitor: Any?

        public func install(binding: Binding<Bool>) {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                DispatchQueue.main.async {
                    binding.wrappedValue = event.modifierFlags.contains(.shift)
                }
                return event
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

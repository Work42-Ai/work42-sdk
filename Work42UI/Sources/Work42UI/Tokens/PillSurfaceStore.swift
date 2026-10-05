// PillSurfaceStore.swift — live-tunable dictation-pill surface config, shared
// across processes (Work42App writes it from Settings; Work42Menu's live pill
// and Work42App's accessories read it).
//
// Why this exists: the pill/accessory surfaces are SwiftUI Liquid Glass, whose
// active/inactive appearance Apple ties to the host window's REAL focus — there
// is no API to pin it "always active" on a floating/non-activating window, so it
// washes out (gets lighter) on focus loss. Rather than hardcode one shade, Yan
// tunes the surface live from Settings: dark/light tint darkness, transparency,
// and a STYLE choice between native Liquid Glass with a small focus-independent
// tint reinforcement and an always-active vibrancy surface. These values must
// reach the pill, which renders in a SEPARATE
// process (Work42Menu) — so, exactly like `ThemeStore`/`selection.json`, they
// live in a tiny JSON at `~/.work42/pill/surface.json` that both processes read,
// with a Darwin notification to push changes live.
//
// Lives in Work42UI (not Work42PillUI) so BOTH `Work42PillUI.DictationPill` and
// `Work42UI.PillBirthView` can read the same values — the dependency only runs
// Work42PillUI→Work42UI, never the reverse (same reason `PillGlassToken` lives
// here). Work42UI has no Work42Core dep, so the path is derived via
// `NSHomeDirectory()` directly, like `ThemeStore.swift`.

import AppKit
import Foundation
import SwiftUI
import notify
import os

/// Diagnostic logger for the pill-surface system (both processes). Capture live:
///   log stream --level debug --predicate 'subsystem == "com.work42.pill"'
/// Added per Yan ("I don't want you to keep guessing — add logs around all of
/// this"): every config load/change, every key/main window transition on the
/// pill windows, and every render-path choice logs here so wash-out reports can
/// be correlated with hard state instead of theories.
public nonisolated let pillSurfaceLog = Logger(subsystem: "com.work42.pill", category: "surface")

/// Short process tag for cross-process log correlation ("Work42App" vs "Work42Menu").
public nonisolated var pillLogProc: String {
    ProcessInfo.processInfo.processName
}

// MARK: - Config

/// The tunable pill-surface parameters. Encoded to `surface.json`.
/// `nonisolated` (pure Sendable data) so it's readable on the draw path under
/// this module's default main-actor isolation.
public nonisolated struct PillSurfaceConfig: Codable, Equatable, Sendable {
    /// Greyscale tint value (0…1) used in DARK appearance. Lower = darker.
    public var darkTintWhite: Double
    /// Greyscale tint value (0…1) used in LIGHT appearance.
    public var lightTintWhite: Double
    /// Fill/tint opacity (0…1) in DARK appearance — the surface translucency.
    /// Separate from `lightTransparency` (Yan: "separate toggles... so we can
    /// have separate things") since a shade that reads right in dark mode can
    /// read wrong in light mode at the same alpha.
    public var darkTransparency: Double
    /// Fill/tint opacity (0…1) in LIGHT appearance.
    public var lightTransparency: Double
    /// `"glass"` = native Liquid Glass with stable tint reinforcement;
    /// `"solid"` = an always-active vibrancy surface with NO glass (never washes).
    public var style: String

    public init(darkTintWhite: Double, lightTintWhite: Double, darkTransparency: Double, lightTransparency: Double, style: String) {
        self.darkTintWhite = darkTintWhite
        self.lightTintWhite = lightTintWhite
        self.darkTransparency = darkTransparency
        self.lightTransparency = lightTransparency
        self.style = style
    }

    /// The shipped defaults. Light appearance preserves the dense near-black
    /// glass tuned before the appearance palette was split; dark appearance
    /// uses a lighter silver tint so it remains distinct from dark content.
    public static let `default` = PillSurfaceConfig(
        darkTintWhite: 0.68, lightTintWhite: 0.02,
        darkTransparency: 0.28, lightTransparency: 0.8826612903225807,
        style: "glass"
    )

    public func tintWhite(for scheme: ColorScheme) -> Double {
        scheme == .light ? lightTintWhite : darkTintWhite
    }

    public func transparency(for scheme: ColorScheme) -> Double {
        scheme == .light ? lightTransparency : darkTransparency
    }

    /// True when the surface renders as always-active vibrancy with no glass.
    public var isSolid: Bool { style == "solid" }

    /// The pre-split single opacity key, read only for migrating an older
    /// `surface.json` (before dark/light transparency were separated).
    private enum LegacyKey: String, CodingKey { case transparency }

    // Tolerant decode: a missing key (e.g. an older file, or the pre-split
    // single `transparency` key) falls back to sane defaults for THAT field
    // rather than discarding the whole config.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PillSurfaceConfig.default
        darkTintWhite  = (try? c.decode(Double.self, forKey: .darkTintWhite))  ?? d.darkTintWhite
        lightTintWhite = (try? c.decode(Double.self, forKey: .lightTintWhite)) ?? d.lightTintWhite
        let legacyContainer = try? decoder.container(keyedBy: LegacyKey.self)
        let legacy = try? legacyContainer?.decode(Double.self, forKey: .transparency)
        darkTransparency  = (try? c.decode(Double.self, forKey: .darkTransparency))  ?? legacy.flatMap { $0 } ?? d.darkTransparency
        lightTransparency = (try? c.decode(Double.self, forKey: .lightTransparency)) ?? legacy.flatMap { $0 } ?? d.lightTransparency
        style = (try? c.decode(String.self, forKey: .style)) ?? d.style
    }
}

// MARK: - Nonisolated snapshot (the draw-path read)

/// A thread-safe, nonisolated snapshot of the current config that `PillGlassToken`
/// reads on the SwiftUI draw path from any context. `PillSurfaceRuntime` (main
/// actor) keeps it in lockstep with its `@Published` value. Mirrors the
/// nonisolated/isolated split `ThemeRuntime`/`ThemeStore` use.
public nonisolated enum PillSurfaceState {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _config = PillSurfaceConfig.default
    public static var config: PillSurfaceConfig {
        get { lock.lock(); defer { lock.unlock() }; return _config }
        set { lock.lock(); _config = newValue; lock.unlock() }
    }
}

// MARK: - Store (filesystem)

/// Reads/writes `~/.work42/pill/surface.json` (atomic write, torn-read safe) and
/// carries the cross-process change signal. Modeled on `ThemeStore`.
public nonisolated enum PillSurfaceStore {
    /// Payloadless Darwin notification posted on every write (both processes wake
    /// and re-read). Same mechanism family as `DictationChannel`.
    public static let changedNotification = "com.work42.pill.surface.changed"

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".work42/pill/surface.json")
    }

    /// Reads the config, or `.default` when the file is absent/unparseable.
    public static func read(from file: URL? = nil) -> PillSurfaceConfig {
        let url = file ?? defaultURL
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(PillSurfaceConfig.self, from: data)
        else { return .default }
        return cfg
    }

    /// Atomically persists the config and wakes readers (temp-file-then-rename,
    /// safe for concurrent readers — exactly `ThemeStore.writeSelection`).
    public static func write(_ config: PillSurfaceConfig, to file: URL? = nil) throws {
        let url = file ?? defaultURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: url, options: .atomic)
        notify_post(changedNotification)
    }
}

// MARK: - Runtime (SwiftUI observation + cross-process refresh)

/// Main-actor observable that SwiftUI views watch so a config change re-renders
/// the pill/accessory. Reads the store on init, keeps the nonisolated
/// `PillSurfaceState` snapshot in sync, and refreshes on the Darwin notification
/// (so a Settings slide in Work42App updates the live pill in Work42Menu).
@MainActor
public final class PillSurfaceRuntime: ObservableObject {
    public static let shared = PillSurfaceRuntime()

    @Published public private(set) var config: PillSurfaceConfig
    private var token: Int32 = -1

    private init() {
        let cfg = PillSurfaceStore.read()
        config = cfg
        PillSurfaceState.config = cfg
        pillSurfaceLog.info("[\(pillLogProc, privacy: .public)] runtime INIT style=\(cfg.style, privacy: .public) dark=\(cfg.darkTintWhite) light=\(cfg.lightTintWhite) alphaD=\(cfg.darkTransparency) alphaL=\(cfg.lightTransparency)")
        var t: Int32 = -1
        let status = notify_register_dispatch(
            PillSurfaceStore.changedNotification, &t, DispatchQueue.main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        if status == UInt32(NOTIFY_STATUS_OK) { token = t }
        pillSurfaceLog.info("[\(pillLogProc, privacy: .public)] darwin-notify observer registered=\(status == UInt32(NOTIFY_STATUS_OK))")
    }

    /// Re-read from disk; no-op if unchanged (cheap enough for the 0.4s pill tick).
    public func reload() {
        let cfg = PillSurfaceStore.read()
        guard cfg != config else { return }
        pillSurfaceLog.info("[\(pillLogProc, privacy: .public)] RELOAD \(self.config.style, privacy: .public)→\(cfg.style, privacy: .public) dark=\(cfg.darkTintWhite) light=\(cfg.lightTintWhite) alphaD=\(cfg.darkTransparency) alphaL=\(cfg.lightTransparency)")
        config = cfg
        PillSurfaceState.config = cfg
    }

    /// Live, IN-PROCESS only (no disk write) — for slider dragging, so the
    /// accessory + Settings preview update every frame without a file-write storm.
    public func preview(_ cfg: PillSurfaceConfig) {
        guard cfg != config else { return }
        config = cfg
        PillSurfaceState.config = cfg
    }

    /// Persist to disk + notify the other process (the live pill). Call on commit
    /// — slider release / picker change — not on every drag tick.
    public func commit(_ cfg: PillSurfaceConfig) {
        preview(cfg)
        try? PillSurfaceStore.write(cfg)
        pillSurfaceLog.info("[\(pillLogProc, privacy: .public)] COMMIT style=\(cfg.style, privacy: .public) dark=\(cfg.darkTintWhite) light=\(cfg.lightTintWhite) alphaD=\(cfg.darkTransparency) alphaL=\(cfg.lightTransparency)")
    }
}

// MARK: - Always-active vibrancy (the "solid" style's material)

/// The NSVisualEffectView behind the "solid" surface, with diagnostic logging on
/// window attach so we can verify its pinned `.active` state on-device.
public final class PillVibrancyNSView: NSVisualEffectView {
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let win = window.map { "win#\($0.windowNumber)" } ?? "nil"
        pillSurfaceLog.info("[\(pillLogProc, privacy: .public)] vibrancy attached \(win, privacy: .public) state=\(self.state == .active ? "active" : "other", privacy: .public) material=\(self.material.rawValue)")
    }
}

/// An `NSVisualEffectView` pinned to `.active` — translucent + focus-independent
/// (never desaturates when the window loses key/app focus, unlike Liquid Glass).
/// In the "solid" style this IS the surface material — the glass is not drawn at
/// all, because inactive Liquid Glass composites its own brighter frost IN FRONT
/// of anything behind it (verified on-device: an opaque floor behind the glass
/// still brightened on focus loss — the wash is the glass layer itself).
public struct AlwaysActiveVibrancy: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> PillVibrancyNSView {
        let v = PillVibrancyNSView()
        v.state = .active               // never follows window/app active state
        v.blendingMode = .behindWindow  // blurs the desktop/window behind → real translucency
        v.material = .underWindowBackground
        v.isEmphasized = true
        return v
    }
    public func updateNSView(_ v: PillVibrancyNSView, context: Context) {
        v.state = .active
    }
}

public extension View {
    /// Keeps the configured tint visible after Liquid Glass has composited its
    /// active/inactive frost. macOS weakens `Glass.tint` for non-key windows;
    /// this post-glass multiply layer preserves the configured appearance tint
    /// without replacing the native glass, its highlights, or its refraction.
    func pillPersistentGlassTint<S: Shape>(_ shape: S, tint: Color) -> some View {
        overlay(
            shape
                .fill(tint)
                .blendMode(.multiply)
                .allowsHitTesting(false)
        )
    }

    /// The pill family's SOLID surface: always-active vibrancy + the tuned
    /// translucent tint, clipped to `shape` — with NO Liquid Glass anywhere in
    /// the stack. Focus-independent by construction: every layer here renders
    /// identically whether the window is key, the app is active, or neither.
    /// Used when `PillSurfaceConfig.style == "solid"`; the "glass" style keeps
    /// pure `.glassEffect` (which visibly brightens off-focus — platform-tied).
    func pillSolidSurface<S: InsettableShape>(_ shape: S, tint: Color) -> some View {
        background(
            ZStack {
                AlwaysActiveVibrancy()
                shape.fill(tint)
            }
            .clipShape(shape)
        )
        .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

// MARK: - Union goo surface (solid-style multi-blob morphs)

/// One blob of a multi-shape solid-style morph (a rounded rect in the stage's
/// coordinate space; `cornerRadius == min(w,h)/2` makes it a capsule).
public nonisolated struct PillGooBlob: Sendable, Equatable {
    public var rect: CGRect
    public var cornerRadius: CGFloat
    public init(rect: CGRect, cornerRadius: CGFloat) {
        self.rect = rect
        self.cornerRadius = cornerRadius
    }
}

/// ONE solid-style surface for a multi-blob morph (hover-split circles, the
/// birth's nub + card): a single vibrancy + tint layer masked by the UNION of
/// every blob, rendered via a Canvas blur + alpha-threshold metaball.
///
/// Why a union mask and not per-blob surfaces: with a translucent tint, three
/// coincident per-blob capsules read as THREE stacked pills (the overlaps
/// compound the alpha and each edge shows) — exactly the "3 pills resizing on
/// top of each other" Yan caught in the hover split. Masking one surface with
/// the union gives uniform translucency across the whole silhouette, so the
/// morph reads as ONE pill dividing again. The blur+threshold also restores
/// the liquid NECKING between separating blobs that `GlassEffectContainer`
/// provides natively on the glass path (`goo` = blur radius; 0 = crisp union).
/// Focus-independent like every solid-style layer (no glass anywhere).
public struct PillGooSolidSurface: View {
    let tint: Color
    let goo: CGFloat
    let blobs: [PillGooBlob]

    public init(tint: Color, goo: CGFloat, blobs: [PillGooBlob]) {
        self.tint = tint
        self.goo = goo
        self.blobs = blobs
    }

    public var body: some View {
        ZStack {
            AlwaysActiveVibrancy()
            Rectangle().fill(tint)
        }
        .mask(unionMask)
        .allowsHitTesting(false)
    }

    /// Opaque union of all blobs. The alphaThreshold collapses the blurred
    /// alpha back to a hard 0/1 edge at the 50% contour, so the mask is
    /// uniform-opacity everywhere — overlaps can't double-expose the tint.
    private var unionMask: some View {
        Canvas { ctx, _ in
            ctx.addFilter(.alphaThreshold(min: 0.5, color: .black))
            if goo > 0.01 {
                ctx.addFilter(.blur(radius: goo))
            }
            ctx.drawLayer { layer in
                for b in blobs where b.rect.width > 0.5 && b.rect.height > 0.5 {
                    layer.fill(
                        Path(roundedRect: b.rect, cornerRadius: b.cornerRadius, style: .continuous),
                        with: .color(.black)
                    )
                }
            }
        }
    }
}

/// One non-compounding tint layer for a group of native Liquid Glass blobs.
/// The union mask is necessary while split/birth shapes overlap: tinting each
/// blob separately would stack alpha and briefly reveal multiple dark pills.
public struct PillGooTintOverlay: View {
    let tint: Color
    let goo: CGFloat
    let blobs: [PillGooBlob]

    public init(tint: Color, goo: CGFloat, blobs: [PillGooBlob]) {
        self.tint = tint
        self.goo = goo
        self.blobs = blobs
    }

    public var body: some View {
        Rectangle()
            .fill(tint)
            .blendMode(.multiply)
            .mask(unionMask)
            .allowsHitTesting(false)
    }

    private var unionMask: some View {
        Canvas { ctx, _ in
            ctx.addFilter(.alphaThreshold(min: 0.5, color: .black))
            if goo > 0.01 {
                ctx.addFilter(.blur(radius: goo))
            }
            ctx.drawLayer { layer in
                for b in blobs where b.rect.width > 0.5 && b.rect.height > 0.5 {
                    layer.fill(
                        Path(roundedRect: b.rect, cornerRadius: b.cornerRadius, style: .continuous),
                        with: .color(.black)
                    )
                }
            }
        }
    }
}

import AppKit
import QuartzCore
import Testing
@testable import Work42UI

@MainActor
private func host(_ playback: Loader42.Playback) -> (Loader42View, NSWindow) {
    let view = Loader42View(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    view.reduceMotionOverride = false
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderBack(nil)
    view.playback = playback
    settle()
    return (view, window)
}

/// Presentation layers only exist once Core Animation has committed the tree.
@MainActor
private func settle() {
    CATransaction.flush()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}

@MainActor
private func strokeEnds(_ pencils: [CAShapeLayer]) -> [CGFloat] {
    pencils.map { ($0.presentation() ?? $0).strokeEnd }
}

@MainActor
@Suite("Loader42 manual playback")
struct Loader42PlaybackTests {
    @Test func progressZeroPaintsNothing() {
        let (view, window) = host(.manual(progress: 0))
        _ = window
        let all = strokeEnds(view.orangePencils + view.violetPencils)
        #expect(!all.isEmpty)
        #expect(all.allSatisfy { $0 == 0 })
    }

    @Test func progressOnePaintsEverything() {
        let (view, window) = host(.manual(progress: 1))
        _ = window
        #expect(strokeEnds(view.orangePencils + view.violetPencils).allSatisfy { $0 == 1 })
    }

    @Test func fourCompleteLeavesOrangeDoneAndVioletUntouched() {
        let (view, window) = host(.manual(progress: Loader42.fourCompleteProgress))
        _ = window
        #expect(strokeEnds(view.orangePencils).allSatisfy { $0 == 1 })
        #expect(strokeEnds(view.violetPencils).allSatisfy { $0 == 0 })
    }

    @Test func progressIsClamped() {
        let (view, window) = host(.manual(progress: 7))
        _ = window
        #expect(strokeEnds(view.orangePencils + view.violetPencils).allSatisfy { $0 == 1 })
        view.playback = .manual(progress: -3)
        settle()
        #expect(strokeEnds(view.orangePencils + view.violetPencils).allSatisfy { $0 == 0 })
    }

    @Test func manualNeverLoopsAndKeepsOneSetOfAnimations() {
        let (view, window) = host(.manual(progress: 0.2))
        _ = window
        let before = view.orangePencils.first?.animation(forKey: "loader42.paint")
        view.playback = .manual(progress: 0.6)
        settle()
        let after = view.orangePencils.first?.animation(forKey: "loader42.paint")
        #expect(before === after)
        for pencil in view.orangePencils + view.violetPencils {
            for key in pencil.animationKeys() ?? [] {
                #expect((pencil.animation(forKey: key)?.repeatCount ?? 0) <= 1)
            }
        }
    }

    @Test func reducedMotionShowsTheFullMark() {
        let view = Loader42View(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        view.reduceMotionOverride = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.playback = .manual(progress: 0)
        settle()
        #expect(strokeEnds(view.orangePencils + view.violetPencils).allSatisfy { $0 == 1 })
    }

    @Test func backToLoopRestoresTheClockAndLoops() {
        let (view, window) = host(.manual(progress: 0.5))
        _ = window
        view.playback = .loop
        let paint = view.orangePencils.first?.animation(forKey: "loader42.paint")
        #expect(paint?.repeatCount == .infinity)
    }
}

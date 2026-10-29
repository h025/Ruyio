import CoreGraphics
import Foundation
import Testing
@testable import RuyioUI

struct CapturePlacementTests {
    let size = CGSize(width: 300, height: 200)

    @Test func aDragInAnyDirectionPutsThePinBackOverItsRegion() {
        // Down at the top left, up at the bottom right (AppKit y grows upward).
        #expect(CapturePlacement.frame(start: CGPoint(x: 100, y: 700), end: CGPoint(x: 400, y: 500), size: size, windows: [])
                == CGRect(x: 100, y: 500, width: 300, height: 200))
        // Bottom right to top left.
        #expect(CapturePlacement.frame(start: CGPoint(x: 400, y: 500), end: CGPoint(x: 100, y: 700), size: size, windows: [])
                == CGRect(x: 100, y: 500, width: 300, height: 200))
        // The press was noticed a little late: the release corner still places it exactly.
        #expect(CapturePlacement.frame(start: CGPoint(x: 112, y: 690), end: CGPoint(x: 400, y: 500), size: size, windows: [])
                == CGRect(x: 100, y: 500, width: 300, height: 200))
        // Dragged from the bottom left to the top right.
        #expect(CapturePlacement.frame(start: CGPoint(x: 100, y: 500), end: CGPoint(x: 400, y: 700), size: size, windows: [])
                == CGRect(x: 100, y: 500, width: 300, height: 200))
    }

    @Test func aClickFindsTheCapturedWindow() {
        let behind = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let window = CGRect(x: 200, y: 300, width: 300, height: 200)
        let click = CGPoint(x: 250, y: 350)
        #expect(CapturePlacement.frame(start: click, end: click, size: size, windows: [window, behind]) == window)
        // The window under the click must have the capture's size.
        #expect(CapturePlacement.frame(start: click, end: click, size: size, windows: [behind]) == nil)
    }

    @Test func nothingToGoByGivesNoFrame() {
        #expect(CapturePlacement.frame(start: nil, end: nil, size: size, windows: []) == nil)
        #expect(CapturePlacement.frame(start: CGPoint(x: 5, y: 5), end: nil, size: size, windows: []) == nil)
    }

    @Test func aSelectionMovedWhileDraggingKeepsTheCornerUnderThePointer() {
        // Space held mid-drag moved the selection: the drag no longer spans the capture, the corner still holds.
        #expect(CapturePlacement.frame(start: CGPoint(x: 0, y: 900), end: CGPoint(x: 700, y: 300), size: size, windows: [])
                == CGRect(x: 400, y: 300, width: 300, height: 200))
    }

    @Test func aDragOntoTheNextDisplayStaysOnTheFirst() {
        // The main display spans x 0–1512; the pointer went on to a display on its right.
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let width = CGSize(width: 212, height: 200)
        #expect(CapturePlacement.frame(start: CGPoint(x: 1300, y: 500), end: CGPoint(x: 1700, y: 300), size: width, windows: [], screen: main)
                == CGRect(x: 1300, y: 300, width: 212, height: 200))
    }

    @Test func aWobblyClickOnAWindowIsStillAWindowCapture() {
        let window = CGRect(x: 200, y: 300, width: 300, height: 200)
        #expect(CapturePlacement.frame(start: CGPoint(x: 250, y: 350), end: CGPoint(x: 257, y: 346), size: size, windows: [window]) == window)
    }

    @Test func theSelectionIsTheLastPressToEndBeforeTheImage() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        var presses: [CapturePlacement.Press] = []
        // A stray click before the crosshair, the selection, then a click while the helper finished.
        CapturePlacement.record(&presses, down: true, at: CGPoint(x: 1, y: 1), time: t0)
        CapturePlacement.record(&presses, down: false, at: CGPoint(x: 1, y: 1), time: t0.addingTimeInterval(0.1))
        CapturePlacement.record(&presses, down: true, at: CGPoint(x: 100, y: 700), time: t0.addingTimeInterval(1))
        CapturePlacement.record(&presses, down: false, at: CGPoint(x: 400, y: 500), time: t0.addingTimeInterval(2))
        CapturePlacement.record(&presses, down: true, at: CGPoint(x: 900, y: 100), time: t0.addingTimeInterval(2.3))
        CapturePlacement.record(&presses, down: false, at: CGPoint(x: 900, y: 100), time: t0.addingTimeInterval(2.4))
        let selection = CapturePlacement.selection(in: presses, writtenAt: t0.addingTimeInterval(2.1))
        #expect(selection?.start == CGPoint(x: 100, y: 700) && selection?.end == CGPoint(x: 400, y: 500))
        // Without the image's time, the last press that ended.
        #expect(CapturePlacement.selection(in: presses, writtenAt: nil)?.start == CGPoint(x: 900, y: 100))
        // A release without its press is ignored.
        var orphan: [CapturePlacement.Press] = []
        CapturePlacement.record(&orphan, down: false, at: .zero, time: t0)
        #expect(orphan.isEmpty)
    }

    @Test func windowBoundsFlipToAppKitCoordinates() {
        #expect(CapturePlacement.appKitRect(fromWindowBounds: CGRect(x: 10, y: 20, width: 300, height: 200), primaryScreenHeight: 1000)
                == CGRect(x: 10, y: 780, width: 300, height: 200))
    }
}

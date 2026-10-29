import CoreGraphics
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

    @Test func windowBoundsFlipToAppKitCoordinates() {
        #expect(CapturePlacement.appKitRect(fromWindowBounds: CGRect(x: 10, y: 20, width: 300, height: 200), primaryScreenHeight: 1000)
                == CGRect(x: 10, y: 780, width: 300, height: 200))
    }
}

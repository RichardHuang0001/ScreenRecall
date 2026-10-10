import Foundation
import CoreGraphics
import ScreenCaptureKit

enum DisplayResolver {
    static func descriptor(for display: SCDisplay, filter: SCContentFilter, order: Int) -> DisplayDescriptor {
        let scale = Double(filter.pointPixelScale)
        return DisplayDescriptor(
            id: display.displayID,
            order: order,
            pixelWidth: max(1, Int((Double(filter.contentRect.width) * scale).rounded())),
            pixelHeight: max(1, Int((Double(filter.contentRect.height) * scale).rounded())),
            pointPixelScale: scale,
            layoutX: Double(display.frame.origin.x), layoutY: Double(display.frame.origin.y),
            layoutWidth: Double(display.frame.width), layoutHeight: Double(display.frame.height),
            isMirrored: CGDisplayMirrorsDisplay(display.displayID) != kCGNullDirectDisplay
        )
    }
}

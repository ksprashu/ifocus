import CoreGraphics

public enum CoordinateSpace {
    /// Converts a Quartz global rect (top-left of main display, y down) into an AppKit Cocoa rect
    /// (bottom-left of main display, y up).
    /// `primaryHeight` must always be `CGDisplayBounds(CGMainDisplayID()).height`, never the height
    /// of the display containing `r`.
    public static func cocoaRect(fromQuartz r: CGRect, primaryHeight: CGFloat) -> CGRect {
        let s = r.standardized
        return CGRect(x: s.origin.x, y: primaryHeight - s.maxY, width: s.width, height: s.height)
    }

    /// Converts an AppKit Cocoa rect (bottom-left of main display, y up) into a Quartz global rect
    /// (top-left of main display, y down).
    public static func quartzRect(fromCocoa r: CGRect, primaryHeight: CGFloat) -> CGRect {
        let s = r.standardized
        return CGRect(x: s.origin.x, y: primaryHeight - s.maxY, width: s.width, height: s.height)
    }
}

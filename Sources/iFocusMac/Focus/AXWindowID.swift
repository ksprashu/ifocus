import ApplicationServices
import CoreGraphics
import Darwin

public enum AXWindowID {
    public enum ResolverMode: String, Sendable {
        case privateSymbol = "private symbol"
        case publicFallback = "public fallback"
    }

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let resolvedFn: GetWindowFn? = {
        let hiServicesPath = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
        if let handle = dlopen(hiServicesPath, RTLD_LAZY),
           let sym = dlsym(handle, "_AXUIElementGetWindow") {
            return unsafeBitCast(sym, to: GetWindowFn.self)
        }
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        if let sym = dlsym(rtldDefault, "_AXUIElementGetWindow") {
            return unsafeBitCast(sym, to: GetWindowFn.self)
        }
        return nil
    }()

    public static func mode(usePrivateResolver: Bool) -> ResolverMode {
        guard usePrivateResolver, resolvedFn != nil else {
            return .publicFallback
        }
        return .privateSymbol
    }

    public static func windowID(of element: AXUIElement, usePrivateResolver: Bool = true) -> UInt32? {
        guard usePrivateResolver, let fn = resolvedFn else { return nil }
        var windowID: CGWindowID = 0
        let err = fn(element, &windowID)
        guard err == .success, windowID != 0 else { return nil }
        return UInt32(windowID)
    }
}

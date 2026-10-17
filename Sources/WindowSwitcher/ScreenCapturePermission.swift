import CoreGraphics

/// Screen Recording TCC status (needed for other apps' window thumbnails).
enum ScreenCapturePermission {
    static var status: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

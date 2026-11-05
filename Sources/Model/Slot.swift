import AppKit

/// A resolved tile shown in the App Bar.
struct Slot: Equatable {
    let key: String            // AppEntry id
    let displayName: String
    let bundleID: String?
    let url: URL
    let character: String?     // display label of the trigger key
    let keyCode: UInt16?
    let running: Bool
    let active: Bool
    let hidden: Bool
    let icon: NSImage
}

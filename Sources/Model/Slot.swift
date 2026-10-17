import AppKit

/// A resolved slot shown in the App Bar.
struct Slot: Equatable {
    let key: String            // unique id (action id / bundle id / path)
    let displayName: String
    let bundleID: String?
    let url: URL
    let character: String?     // trigger character (lower-cased)
    let running: Bool
    let active: Bool
    let hidden: Bool
    let icon: NSImage
}

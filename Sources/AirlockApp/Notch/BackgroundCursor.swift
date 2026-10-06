import Foundation

/// Lets Airlock's own cursor changes show while another app is in front.
///
/// The window server applies a cursor change only from the ACTIVE app, and
/// Airlock is never the active app: the notch is a non-activating panel, by
/// design, so whatever you were typing in stays frontmost. Every
/// `NSCursor.pointingHand.push()` in `.clickable()` was therefore ignored on
/// the real notch — the owner, 2026-10-01: "I don't see the pointer in the
/// mouse when hovering over questions". It only ever showed while Settings
/// had made Airlock active.
///
/// The connection property below is the window server's own switch for this.
/// It is not public API, so it is looked up at run time and every miss is a
/// silent no-op: a macOS that drops it gives back the arrow, never a crash.
/// Only the pointer over Airlock's own windows is affected — cursor changes
/// come from tracking areas, and those only fire inside the windows that own
/// them.
enum BackgroundCursor {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    /// True when the switch was found and accepted.
    @discardableResult
    static func enable() -> Bool {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connectionSymbol = dlsym(rtldDefault, "_CGSDefaultConnection"),
              let setSymbol = dlsym(rtldDefault, "CGSSetConnectionProperty") else { return false }
        let connection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)()
        let set = unsafeBitCast(setSymbol, to: SetConnectionProperty.self)
        return set(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }
}

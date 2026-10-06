import Foundation
import IOKit

/// This Mac, as one stable string.
///
/// **One licence, one Mac** — so a licence has to name a machine, and the name
/// has to survive everything short of new hardware: a reinstall, a rename, a
/// user account, a new disk.
///
/// `IOPlatformUUID` is the identifier that does. It is not a serial number and
/// carries nothing about the person; it goes into a signed token that never
/// leaves this Mac except to the licence server, and the same token is the
/// thing already carrying an email address.
///
/// Cached because it involves an IOKit lookup and cannot change while the
/// process is alive — if it did, the Mac would have been replaced underneath
/// us.
enum MachineIdentity {
    static let current: String? = lookup()

    private static func lookup() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                 IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        return (value.takeRetainedValue() as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

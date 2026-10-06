import Foundation

/// Whether Airlock is sold at all.
///
/// **Sold again since 1.0.17** (the owner's call, 2026-10-06): the code is
/// published to read, and the download is the paid subscription with its
/// 14-day trial. 1.0.15 and 1.0.16 were free; true here brings that back — no
/// trial, no paywall, no licence notices, no Licence page, and the licence
/// server never contacted.
///
/// Both ways stay built and tested, so changing this is a release, not a
/// rebuild. Read it through `Entitlement.free` where possible, so the rest of
/// the app asks "may I be used" and never "is this the free version".
public enum Pricing {
    public static let isFree = false
}

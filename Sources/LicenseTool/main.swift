import CryptoKit
import Foundation
import AirlockCore

// Issues and inspects Airlock licence keys.
//
//   swift run LicenseTool new-key
//   AIRLOCK_LICENSE_KEY=<private> swift run LicenseTool issue you@example.com yearly
//   AIRLOCK_LICENSE_KEY=<private> swift run LicenseTool issue you@example.com monthly 30
//   swift run LicenseTool check <token>
//
// THE PRIVATE KEY NEVER ENTERS THIS REPOSITORY. It arrives through the
// environment so it cannot be committed by accident, cannot appear in `ps` the
// way an argument would, and cannot end up in shell history if you export it
// from a password manager. Anyone holding it can mint licences forever.
//
// Not a test target and not shipped in the bundle: the app only ever VERIFIES,
// which is the entire point of an asymmetric scheme. The signing half lives
// wherever you fulfil orders — this tool is the same code, for issuing by hand
// and for reading a key a customer has pasted into a support email.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    exit(1)
}

/// How long after the billing date a licence keeps working silently. Fourteen
/// days is enough to cover a holiday, a dead card noticed late, and a bad week
/// for the licence server — all at once.
let defaultGraceDays = 14.0

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("""
    usage:
      new-key                                  create a signing key pair
      pubkey                                   print the public half of $AIRLOCK_LICENSE_KEY
      issue <email> <monthly|yearly> [grace]   mint a licence, grace in days (default \(Int(defaultGraceDays)))
      check <token>                            verify against the public key

    The private key comes from $AIRLOCK_LICENSE_KEY; the public key from
    Configuration/license-public-key.txt.
    """)
    exit(0)
}

func publicKeyFromDisk() -> Data {
    let path = "Configuration/license-public-key.txt"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { fail("no public key at \(path) — run `new-key` first") }
    return data
}

switch command {
case "new-key":
    let key = Curve25519.Signing.PrivateKey()
    print("""
    PUBLIC  (commit to Configuration/license-public-key.txt):
    \(key.publicKey.rawRepresentation.base64EncodedString())

    PRIVATE (store in a password manager — NEVER commit, never paste in chat):
    \(key.rawRepresentation.base64EncodedString())

    Losing the private key means you cannot issue or renew licences; existing
    ones keep working until their `checkBy` and then go overdue. Leaking it
    means anyone can mint their own — which is what the renewal check is for,
    since a leaked key stops being renewable the moment you rotate.
    """)

case "pubkey":
    // Derives rather than stores. The public half is a pure function of the
    // private one, so a backed-up seed is enough to reconstruct everything —
    // and `setup-license-key.sh` uses this to stay idempotent without keeping a
    // second copy of anything that could drift.
    guard let raw = ProcessInfo.processInfo.environment["AIRLOCK_LICENSE_KEY"],
          let keyData = Data(base64Encoded: raw),
          let signer = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    else { fail("set $AIRLOCK_LICENSE_KEY to the base64 private key") }
    print(signer.publicKey.rawRepresentation.base64EncodedString())

case "issue":
    guard arguments.count >= 3 else { fail("usage: issue <email> <monthly|yearly> [grace days]") }
    guard let raw = ProcessInfo.processInfo.environment["AIRLOCK_LICENSE_KEY"],
          let keyData = Data(base64Encoded: raw),
          let signer = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    else { fail("set $AIRLOCK_LICENSE_KEY to the base64 private key") }

    let email = arguments[1]
    guard let period = License.Period(rawValue: arguments[2]) else {
        fail("period must be `monthly` or `yearly`")
    }
    let graceDays = arguments.count >= 4 ? Double(arguments[3]) ?? defaultGraceDays
                                         : defaultGraceDays

    let now = Date()
    // The billing period, then the silence. A refresh replaces the whole token,
    // so these dates are only ever "until the next successful check".
    let renewsAt = now.addingTimeInterval((period == .yearly ? 365 : 30) * 86_400)
    let license = License(id: "lic_\(UUID().uuidString.prefix(8).lowercased())",
                          email: email, product: "airlock", period: period,
                          issued: now, renewsAt: renewsAt,
                          checkBy: renewsAt.addingTimeInterval(graceDays * 86_400))

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    // Sorted keys so the same licence always encodes identically — worth having
    // when you are diffing a support ticket against what you think you issued.
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(license)
    let signature = try signer.signature(for: payload)
    print("\(LicenseVerifier.encode(payload)).\(LicenseVerifier.encode(signature))")

case "check":
    guard arguments.count >= 2 else { fail("usage: check <token>") }
    switch LicenseVerifier.verify(arguments[1], publicKey: publicKeyFromDisk()) {
    case .valid(let license):
        // Authenticity and entitlement are separate answers, and support needs
        // both: "is this key real" and "does it currently work".
        let state: String
        switch Entitlement.resolve(verdict: .valid(license), trialStarted: license.issued) {
        case .licensed: state = "active"
        case .grace: state = "in grace — silent, still working"
        case .overdue: state = "overdue — working, asking"
        case .free, .trialing, .trialExpired: state = "trial"
        }
        print("""
        ✓ genuine · \(license.period.rawValue) · \(license.email) · \(license.id)
          renews  \(license.renewsAt.formatted())
          checkBy \(license.checkBy.formatted())
          now     \(state)
        """)
    case .invalid(let reason):
        fail("invalid (\(reason.rawValue))")
    }

default:
    fail("unknown command: \(command)")
}

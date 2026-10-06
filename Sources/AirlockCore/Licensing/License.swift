import CryptoKit
import Foundation

/// What a licence says about itself, once its signature has been proved.
///
/// Never construct one from untrusted input directly — `LicenseVerifier` is the
/// only way to get one, and it will not hand back a value whose signature has
/// not already been checked. That ordering is the whole design: the classic way
/// to get this wrong is to decode the JSON, read a field like `"valid": true`,
/// and verify afterwards (or not at all).
///
/// **Two dates, and the gap between them is the point.** `renewsAt` is when the
/// billing period ends. `checkBy` is when this app starts caring. Everything
/// between is a grace window in which a failed refresh — a flight, a hotel
/// network, a bad afternoon on the licence server — is completely invisible.
public struct License: Equatable, Sendable, Codable {
    /// The vendor's identifier, for support. Not a secret and not a password.
    public let id: String
    /// Who it was issued to. Shown in Settings so a person can see which of
    /// their addresses a licence is under, which is the actual support question.
    public let email: String
    /// Which product. Checked, so a licence for something else the same key
    /// signs cannot unlock this one.
    public let product: String
    public let period: Period
    public let issued: Date
    /// The end of the paid billing period — what a customer reads as
    /// "renews 4 September".
    public let renewsAt: Date
    /// The hard cutoff: `renewsAt` plus however much grace the issuer allowed.
    /// Nothing visible happens to the customer until this passes.
    ///
    /// Set by the ISSUER rather than computed here, so a support case can be
    /// given more room without shipping an app update. A perpetual licence, if
    /// one is ever sold, needs no new field or code path — it is simply one
    /// whose `checkBy` is far enough away to never arrive.
    public let checkBy: Date
    /// The issuer's own handle on the subscription behind this licence — for
    /// Lemon Squeezy, the licence key it emailed the customer.
    ///
    /// It exists so renewal can be **stateless**: the refresh endpoint verifies
    /// this token, reads the reference back out of it, and asks the payment
    /// provider whether that subscription is still active. No database, nothing
    /// to back up, nothing to lose.
    ///
    /// Optional because a licence issued by hand (`LicenseTool`) has no provider
    /// behind it, and one of those simply never renews itself. **Never logged
    /// and never shown** — it is the customer's own key, but a value that can be
    /// exchanged for a working licence does not belong in a bug report.
    public let ref: String?

    /// The Mac this licence was issued to. **One licence, one Mac.**
    ///
    /// Nil on a licence issued before seats existed, and on hand-issued tokens
    /// where naming a machine would mean knowing one — both are honoured
    /// anywhere, deliberately: a rule added later must not lock somebody out of
    /// something they already bought.
    public let machine: String?

    public enum Period: String, Sendable, Codable {
        case monthly
        case yearly

        /// What this plan costs, for the surfaces that quote it.
        ///
        /// Deliberately NOT stored in the token — see `label` below: prices
        /// change and a signed licence is forever. This is the price the app
        /// *offers* today, which is a build-time fact, and it lives here because
        /// it was previously written out at four call sites. The store URLs had
        /// the identical problem and the identical comment at each copy claiming
        /// to be the one true home.
        ///
        /// If this ever disagrees with Lemon Squeezy, Lemon Squeezy wins — the
        /// customer is charged there, not here.
        public var price: String {
            switch self {
            case .monthly: return "€3.99 a month"
            case .yearly: return "€35.99 a year"
            }
        }

        /// For Settings. Not a price — prices change and a signed licence is
        /// forever, so the token never carries one.
        public var label: String {
            switch self {
            case .monthly: return "Monthly"
            case .yearly: return "Yearly"
            }
        }
    }

    public init(id: String, email: String, product: String, period: Period,
                issued: Date, renewsAt: Date, checkBy: Date, ref: String? = nil,
                machine: String? = nil) {
        self.id = id
        self.email = email
        self.product = product
        self.period = period
        self.issued = issued
        self.renewsAt = renewsAt
        self.checkBy = checkBy
        self.ref = ref
        self.machine = machine
    }
}

public enum LicenseVerdict: Equatable, Sendable {
    /// Genuinely signed, and for this product. Says nothing about whether it is
    /// still in date — see `Entitlement`.
    case valid(License)
    case invalid(Reason)

    public enum Reason: String, Equatable, Sendable {
        case malformed
        /// The signature did not match. Either forged, or edited after issue —
        /// changing a single character of the payload lands here.
        case signature
        /// Signed correctly, but for a different product.
        case wrongProduct
        /// Signed correctly, for this product, and issued to a different Mac.
        ///
        /// **One licence, one Mac.** The binding is in the token itself, so the
        /// refusal is offline and instant — a key forwarded to a colleague
        /// stops at the door rather than after a round trip, and the message
        /// can say why instead of "invalid licence".
        case otherMachine
    }

    public var license: License? {
        switch self {
        case .valid(let license): return license
        case .invalid: return nil
        }
    }
}

/// Checks a licence key against a public key compiled into the app.
///
/// **Authenticity only.** This type answers "did we sign this, and is it ours" —
/// nothing else. It does not look at the clock, because whether a genuine
/// licence still entitles you to anything is policy, it has two dates to weigh,
/// and it belongs in `Entitlement` where it can be read in one place. A
/// signature checker that consults the clock is one that returns "invalid" for a
/// key that is perfectly valid and merely old.
///
/// The signed token is what makes the app work offline: a refresh is the app
/// asking for a *newer* token, and until one arrives the one on disk keeps
/// answering. Between refreshes there is no server in the loop at all.
///
/// Ed25519 via CryptoKit: no dependency, and the same primitive Sparkle uses to
/// sign updates.
public enum LicenseVerifier {
    /// `<base64url(payload)>.<base64url(signature)>` — a compact single-line
    /// token a person can paste. Deliberately not a JWT: no algorithm field,
    /// because a signature scheme the *token* gets to choose is how "alg: none"
    /// happened.
    /// `machine` is this Mac's identifier, or nil to skip the seat check — which
    /// is what `LicenseTool` and the tests want, since neither runs on the Mac a
    /// licence was issued to.
    public static func verify(_ token: String,
                              publicKey: Data,
                              expectedProduct: String = "airlock",
                              machine: String? = nil) -> LicenseVerdict {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payload = decode(String(parts[0])),
              let signature = decode(String(parts[1])) else { return .invalid(.malformed) }

        // SIGNATURE FIRST. Nothing inside the payload is read until it has been
        // proved, so a forged licence never gets to influence a decision.
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: payload) else { return .invalid(.signature) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let license = try? decoder.decode(License.self, from: payload) else {
            return .invalid(.malformed)
        }
        guard license.product == expectedProduct else { return .invalid(.wrongProduct) }
        // Seat last, and only when both sides name a machine. A licence with no
        // machine predates seats or was issued by hand; refusing those would
        // revoke something already paid for to enforce a rule added afterwards.
        if let machine, let issuedTo = license.machine, issuedTo != machine {
            return .invalid(.otherMachine)
        }
        return .valid(license)
    }

    /// base64url, which is what survives being pasted into a text field, an
    /// email and a URL without being mangled.
    private static func decode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    /// Only ever used by the issuing side and by tests — the app verifies and
    /// never signs, which is the point of asymmetric keys.
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

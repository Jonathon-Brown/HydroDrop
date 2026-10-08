import Foundation

// Invite codes and the links that carry them (final design §4.1). One normaliser and one
// strict parser for the whole app: a typed code, a scanned QR code and an opened link all
// come through here, and so does the Android app's, by way of the shared vectors (KV1).

/// A code, and the link secret that came with it if any.
public struct DuoParsedInvite: Equatable, Sendable {
    /// Canonical: eight characters of `0-9A-HJKMNP-TV-Z`.
    public var code: String
    /// 26 Crockford characters, kept exactly as received and never sent to the server.
    public var k: String?

    public init(code: String, k: String? = nil) {
        self.code = code
        self.k = k
    }
}

public enum DuoInviteCode {
    /// Crockford's base32: no I, L, O or U.
    public static let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    public static let length = 8
    public static let secretLength = 26

    private static let alphabetSet = Set(alphabet.unicodeScalars)

    /// The canonical form of something a person typed, or nil if it cannot be a code:
    /// upper case, `O` to `0`, `I` and `L` to `1`, hyphens and spaces dropped, and then
    /// exactly eight characters of the alphabet. Case is folded for ASCII letters only, so
    /// a character like `ß` can never turn into two letters of a code.
    public static func normalize(_ text: String) -> String? {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            var value = scalar.value
            if value == 0x2D || value == 0x20 { continue }
            if value >= 0x61, value <= 0x7A { value -= 0x20 }
            switch value {
            case 0x4F: value = 0x30
            case 0x49, 0x4C: value = 0x31
            default: break
            }
            guard let mapped = Unicode.Scalar(value), alphabetSet.contains(mapped) else { return nil }
            result.append(mapped)
        }
        return result.count == length ? String(result) : nil
    }

    /// `H7K3-9QWX`.
    public static func display(_ canonical: String) -> String {
        guard canonical.count == length else { return canonical }
        return "\(canonical.prefix(4))-\(canonical.suffix(4))"
    }

    /// What a person might paste into the code field: a whole link, or a code. Nil if it is
    /// neither.
    public static func parse(pasted text: String) -> DuoParsedInvite? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http"), let url = URL(string: trimmed) {
            return DuoLink.parse(url)
        }
        return normalize(trimmed).map { DuoParsedInvite(code: $0) }
    }

    /// Whether `text` is a link secret: 26 characters of the alphabet, as it is, case and all.
    public static func isLinkSecret(_ text: String) -> Bool {
        text.unicodeScalars.count == secretLength && text.unicodeScalars.allSatisfy { alphabetSet.contains($0) }
    }
}

public enum DuoLink {
    public static let scheme = "https"
    public static let host = "hydrodrop.us"
    public static let path = "/duo"

    /// The strict parser. The scheme is `https`, the host `hydrodrop.us`, the path `/duo`,
    /// and the fragment is the code, then optionally a `.` and the 26-character secret.
    /// Anything else, a query string included, is not a Duo link. The code is normalised
    /// (a link retyped in lower case still works); the secret is kept verbatim.
    public static func parse(_ url: URL) -> DuoParsedInvite? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host, url.path == path,
              url.query == nil, let fragment = url.fragment else { return nil }
        let parts = fragment.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let code = DuoInviteCode.normalize(String(first)) else { return nil }
        if parts.count == 1 { return DuoParsedInvite(code: code) }
        let secret = String(parts[1])
        guard DuoInviteCode.isLinkSecret(secret) else { return nil }
        return DuoParsedInvite(code: code, k: secret)
    }

    /// `https://hydrodrop.us/duo#H7K39QWX.<k>`, or without the secret for a typed code. The
    /// secret rides in the fragment, which no server and no link preview ever receives.
    public static func url(code: String, k: String?) -> URL? {
        var text = "\(scheme)://\(host)\(path)#\(code)"
        if let k { text += ".\(k)" }
        return URL(string: text)
    }
}

public enum DuoLinkSecret {
    /// 128 random bits as 26 Crockford characters, made on the inviter's phone and stored on
    /// both (§4.1). Nothing in v1 encrypts with it; it is the hook that lets a later version
    /// turn encryption on without re-pairing.
    public static func make(random: DuoRandom) -> String {
        let bytes = random.bytes(16)
        let alphabet = Array(DuoInviteCode.alphabet)
        var buffer = 0
        var bits = 0
        var result = ""
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                result.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { result.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return result
    }
}

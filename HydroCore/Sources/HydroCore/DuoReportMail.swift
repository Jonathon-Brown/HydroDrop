import Foundation

/// The mail Report a problem opens (final design §11.8): a reason picked from three, the duo's
/// id and the person's Support ID, to `support@hydrodrop.us`, and nothing else. There is no
/// free text and no name: the reason is one of `Reason`'s cases, the duo is a `UUID` and the
/// Support ID is printed only if it is one, so no caller can put a name, a code or a token in
/// it. Support resolves the Support ID through the admin tool (§3.7); the duo id says which
/// duo, since a person can be in five.
///
/// The mail is the person's to send: the app only opens it, in the mail composer or through a
/// `mailto:` link, and nothing leaves until they tap Send there. It goes from their own address,
/// so the mail app adds what every mail carries (their address and the name on it, perhaps a
/// signature), and they can edit the body; the sheet's line above Send says so (`explanation`).
/// While the restore question is up the caller passes no Support ID, so the mail says "unknown"
/// (`DuoDiagnosticsExport.shownSupportID`, D76).
public enum DuoReportMail {
    /// The three reasons, in the order the sheet lists them. The words are `DuoCopy.reportReasons`
    /// (approved); this only gives each a case, so the mail cannot carry anything else.
    public enum Reason: Int, CaseIterable, Identifiable, Sendable {
        case offensiveName = 0
        case unwantedNudges = 1
        case notThePersonIInvited = 2

        public var id: Int { rawValue }
        public var text: String { DuoCopy.reportReasons[rawValue] }
    }

    /// The support address the app already uses (`BugReportView`, the banned banner).
    public static let recipient = "support@hydrodrop.us"
    /// NEW COPY, the brief's placeholder: the mail goes out under the person's own name, so its
    /// wording is Jonathon's to approve.
    public static let subject = "Duo report" // NEW COPY
    /// The body's three labels and what the Support ID reads as before `GET /me` has answered,
    /// while the restore question is up, or when what it said is not a Support ID.
    public static let reasonLabel = "Reason" // NEW COPY
    public static let duoLabel = "Duo" // NEW COPY
    public static let supportIDLabel = DuoDiagnosticsExport.Label.supportID // NEW COPY
    public static let unknownSupportID = "unknown" // NEW COPY

    /// The Report sheet's line above Send. It used to end "Nothing else is sent.", which was not
    /// true: the mail goes from the person's own address, with the name on it and whatever the
    /// mail app adds, and they can change it before sending. NEW COPY (the stage review's
    /// wording, 2026-10-08, awaiting Jonathon's approval with the rest).
    public static let explanation = "This opens an email to support, from your own email address, with the reason you picked, this duo's id and your Support ID. You can read it before you send it." // NEW COPY

    /// The mail, prefilled: `Reason: <reason>`, `Duo: <the duo's lowercase id>`,
    /// `Support ID: <XXXX-XXXX-XXXX or unknown>`, one per line.
    public static func make(reason: Reason, duoID: UUID, supportID: String?) -> (recipient: String, subject: String, body: String) {
        let support = DuoDiagnosticsExport.displaySupportID(supportID) ?? unknownSupportID
        let body = [
            "\(reasonLabel): \(reason.text)",
            "\(duoLabel): \(duoID.uuidString.lowercased())",
            "\(supportIDLabel): \(support)",
        ].joined(separator: "\n")
        return (recipient, subject, body)
    }

    /// The same mail as a `mailto:` link, for a phone with no account in Mail.
    public static func mailtoURL(reason: Reason, duoID: UUID, supportID: String?) -> URL? {
        let mail = make(reason: reason, duoID: duoID, supportID: supportID)
        return mailtoURL(recipient: mail.recipient, subject: mail.subject, body: mail.body)
    }

    /// `mailto:<recipient>?subject=<subject>&body=<body>` as RFC 6068 has it: every character
    /// of the subject and the body other than the unreserved ones is percent-encoded, a space
    /// as `%20` (never `+`, which mail apps read as a plus or as a space depending on whose
    /// they are) and a line break as `%0D%0A`. `URLComponents.queryItems`, which the bug report
    /// uses, leaves `+` alone, so a `+` in the export (a zone such as `Etc/GMT+5`) could
    /// arrive as a space; this does not. Nil only for a recipient that is not a plain address.
    public static func mailtoURL(recipient: String, subject: String, body: String) -> URL? {
        let addressCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._@")
        guard !recipient.isEmpty, recipient.unicodeScalars.allSatisfy({ addressCharacters.contains($0) }),
              recipient.filter({ $0 == "@" }).count == 1 else { return nil }
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        guard let subject = subject.addingPercentEncoding(withAllowedCharacters: unreserved),
              let body = lines.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "mailto:\(recipient)?subject=\(subject)&body=\(body)")
    }

    /// RFC 3986's unreserved characters, the only ones left as they are.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

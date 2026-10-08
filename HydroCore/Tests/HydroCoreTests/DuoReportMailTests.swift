import XCTest
@testable import HydroCore

/// Stage M: the mail Report a problem opens (final design §11.8). It goes out under the person's
/// name, so it carries the reason they picked, the duo's id and their Support ID, and nothing
/// else: no free text, no name.
final class DuoReportMailTests: XCTestCase {
    private let duoID = UUID(uuidString: "6D2A0F3C-1111-4000-8000-000000000001")!

    func testTheMailIsTheReasonTheDuoAndTheSupportIDAndNothingElse() {
        let mail = DuoReportMail.make(reason: .unwantedNudges, duoID: duoID, supportID: "ABCD1234EFGH")
        XCTAssertEqual(mail.recipient, "support@hydrodrop.us")
        XCTAssertEqual(mail.subject, "Duo report")
        XCTAssertEqual(mail.body, "Reason: Unwanted nudges\nDuo: 6d2a0f3c-1111-4000-8000-000000000001\nSupport ID: ABCD-1234-EFGH")
        XCTAssertEqual(DuoReportMail.make(reason: .unwantedNudges, duoID: duoID, supportID: "ABCD-1234-EFGH").body, mail.body,
                       "the shown form of the Support ID makes the same mail")
    }

    func testEachReasonIsTheApprovedWording() {
        XCTAssertEqual(DuoReportMail.Reason.allCases.map(\.text), DuoCopy.reportReasons,
                       "one case per approved reason, in the order the sheet lists them")
        XCTAssertEqual(DuoReportMail.Reason.allCases.map(\.rawValue), [0, 1, 2], "the sheet's ids are duo.report.reason.0 to .2")
        for reason in DuoReportMail.Reason.allCases {
            let lines = DuoReportMail.make(reason: reason, duoID: duoID, supportID: nil).body.components(separatedBy: "\n")
            XCTAssertEqual(lines.count, 3)
            XCTAssertEqual(lines[0], "Reason: \(DuoCopy.reportReasons[reason.rawValue])")
            XCTAssertEqual(lines[1], "Duo: 6d2a0f3c-1111-4000-8000-000000000001")
        }
    }

    func testASupportIDThatIsNotOneReadsUnknown() {
        for value in [nil, "", "Samantha Quill", "abcd1234efgh", "ABCD1234EFG", "ABCDI234EFGH", "ABCD-1234-EFGHX", "jo@example.com"] {
            let body = DuoReportMail.make(reason: .offensiveName, duoID: duoID, supportID: value).body
            XCTAssertTrue(body.hasSuffix("\nSupport ID: unknown"), "\(value ?? "nil") should read as unknown")
            if let value, !value.isEmpty { XCTAssertFalse(body.contains(value)) }
        }
    }

    func testTheMailtoLinkRoundTripsToTheSameMail() throws {
        for reason in DuoReportMail.Reason.allCases {
            for supportID in ["ABCD1234EFGH", nil] {
                let mail = DuoReportMail.make(reason: reason, duoID: duoID, supportID: supportID)
                let url = try XCTUnwrap(DuoReportMail.mailtoURL(reason: reason, duoID: duoID, supportID: supportID))
                let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
                XCTAssertEqual(components.scheme, "mailto")
                XCTAssertEqual(components.path, "support@hydrodrop.us")
                let items = components.queryItems ?? []
                XCTAssertEqual(items.map(\.name), ["subject", "body"], "a subject and a body, and nothing else (no cc, no bcc)")
                XCTAssertEqual(items.first?.value, mail.subject)
                XCTAssertEqual(items.last?.value, mail.body.replacingOccurrences(of: "\n", with: "\r\n"),
                               "RFC 6068: a line break in the body is %0D%0A")
                XCTAssertTrue(url.absoluteString.contains("%0D%0A"))
                XCTAssertFalse(url.absoluteString.contains(" "))
            }
        }
    }

    func testTheLinkEncodesEverythingButTheUnreservedCharacters() throws {
        let subject = "a+b&c=d#e%f?g h/ü—;'"
        let body = "first line+plus & amp = equals # hash % percent\nsecond line ü—\r\nthird\rfourth"
        let url = try XCTUnwrap(DuoReportMail.mailtoURL(recipient: "support@hydrodrop.us", subject: subject, body: body))
        let raw = url.absoluteString
        let query = String(raw.dropFirst("mailto:support@hydrodrop.us?".count))
        XCTAssertTrue(raw.hasPrefix("mailto:support@hydrodrop.us?subject="))
        XCTAssertFalse(query.contains("+"), "a plus is %2B, never itself, which some mail apps read as a space")
        XCTAssertTrue(query.contains("%2B"))
        XCTAssertTrue(query.contains("%20"))
        XCTAssertEqual(query.filter { $0 == "&" }.count, 1, "the one & is the separator; the body's own is encoded")
        XCTAssertEqual(query.filter { $0 == "=" }.count, 2)
        XCTAssertFalse(query.contains("#") || query.contains("?") || query.contains("/") || query.contains("'") || query.contains(";"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first?.value, subject)
        XCTAssertEqual(items.last?.value, "first line+plus & amp = equals # hash % percent\r\nsecond line ü—\r\nthird\r\nfourth",
                       "every kind of line break arrives as CRLF")
    }

    func testARecipientThatIsNotAPlainAddressMakesNoLink() {
        for recipient in ["", "support hydrodrop.us", "support@hydrodrop.us?cc=someone@example.com", "a@b@c", "support@hydrodrop.us&body=x"] {
            XCTAssertNil(DuoReportMail.mailtoURL(recipient: recipient, subject: "s", body: "b"), recipient)
        }
        XCTAssertNotNil(DuoReportMail.mailtoURL(recipient: "support@hydrodrop.us", subject: "s", body: "b"))
    }

    /// The words the person sees and sends, pinned together (M1): the sheet's line above Send no
    /// longer claims "Nothing else is sent", which the mail app's own sender line made untrue.
    func testTheSheetsLineAndTheMailsWordsAreTheOnesAwaitingApproval() {
        XCTAssertEqual(DuoReportMail.explanation, "This opens an email to support, from your own email address, with the reason you picked, this duo's id and your Support ID. You can read it before you send it.")
        XCTAssertFalse(DuoReportMail.explanation.contains("Nothing else"))
        XCTAssertEqual(DuoReportMail.subject, "Duo report")
        XCTAssertEqual([DuoReportMail.reasonLabel, DuoReportMail.duoLabel, DuoReportMail.supportIDLabel, DuoReportMail.unknownSupportID],
                       ["Reason", "Duo", "Support ID", "unknown"])
        XCTAssertEqual(DuoReportMail.recipient, "support@hydrodrop.us")
    }

    /// D76: while the restore question is up the mail carries no Support ID, since the identity
    /// may be the previous owner's.
    func testWhileTheRestoreQuestionIsUpTheMailSaysUnknown() {
        let restore = DuoAvailability.needsRestoreChoice(DuoRestorePrompt(partnerName: "Samantha", myName: "Jonathon"))
        let mail = DuoReportMail.make(reason: .offensiveName, duoID: duoID,
                                      supportID: DuoDiagnosticsExport.shownSupportID("ABCD1234EFGH", availability: restore))
        XCTAssertTrue(mail.body.hasSuffix("\nSupport ID: unknown"))
        XCTAssertFalse(mail.body.contains("ABCD") || mail.body.contains("Samantha") || mail.body.contains("Jonathon"))
    }
}

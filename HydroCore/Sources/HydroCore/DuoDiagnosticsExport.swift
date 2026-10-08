import Foundation

/// What Settings > Duo Streaks > Diagnostics shows, and the plain text Export diagnostics puts
/// in a mail (final design §10.8): the Support ID, the tier, the app and iOS versions, the
/// service's state, the op-queue length, the last push upload, per duo its seq, cursor, last
/// fetch, last write and last error, the last five errors and the last ten responses.
///
/// The screen and the export are drawn from one `Report`, so they cannot say different
/// things. Everything in it leaves the phone by email when the person taps Send, so the
/// function takes ids, numbers, error codes and dates only, and every string it is handed
/// passes a filter before it is printed: the Support ID must be the contract's twelve
/// Crockford characters, an error code one this build writes, a request id the exact shape the
/// Worker writes (and only its 16 hex characters are printed), a zone a time zone Foundation
/// knows, and a version digits and dots. An HTTP status outside 100 to 599 is not one.
/// A string that fails reads as a dash. That matters for two inputs above all: the
/// availability, whose restore question carries the partner's name and the person's own
/// (`needsRestoreChoice(DuoRestorePrompt)`), is printed as one fixed word per state, never
/// through string interpolation of the value; and the diagnostics come back from the App
/// Group defaults, which this code did not write, so it trusts none of their strings.
///
/// What still prints as given is a counter: a duo's seq and cursor, the queue's length and the
/// window's minutes are numbers whatever they hold. A number is never a name, a code or a key,
/// but a hostile defaults blob could make one look like a phone number.
public enum DuoDiagnosticsExport {
    /// The words of the screen and the export. NEW COPY: every one of these awaits Jonathon's
    /// approval (plan P2 lists "Recent requests"; the rest are row labels the brief describes
    /// but does not word). "App version" and "iOS version" are the app's existing bug-report
    /// labels (`Diagnostics.summary`).
    public enum Label {
        /// The export's first line: the feature's name, as a heading. NEW COPY (as a heading).
        public static let title = "Duo Streaks" // NEW COPY
        public static let exportedAt = "Exported" // NEW COPY
        public static let supportID = "Support ID" // NEW COPY (the final design's term, §3.7)
        public static let tier = "Tier" // NEW COPY
        public static let appVersion = "App version" // existing (Diagnostics.summary)
        public static let systemVersion = "iOS version" // existing (Diagnostics.summary)
        public static let availability = "Availability" // NEW COPY
        public static let queuedOps = "Queued requests" // NEW COPY
        public static let notifications = "Notifications" // NEW COPY
        public static let notificationsEnabled = "Enabled" // NEW COPY
        public static let timeZone = "Time zone" // NEW COPY
        public static let window = "Window" // NEW COPY
        public static let lastUpload = "Last upload" // NEW COPY
        public static let seq = "Seq" // NEW COPY
        public static let cursor = "Cursor" // NEW COPY
        public static let lastFetch = "Last fetch" // NEW COPY
        public static let lastWrite = "Last write" // NEW COPY
        public static let lastError = "Last error" // NEW COPY
        public static let recentErrors = "Recent errors" // NEW COPY
        public static let recentRequests = "Recent requests" // NEW COPY (named in plan P2)
        public static let on = "on" // NEW COPY
        public static let off = "off" // NEW COPY
        /// What a fact nobody has told the phone yet reads as, such as the Support ID before
        /// `GET /me` has answered.
        public static let none = "—"
        /// "Duo 6d2a0f3c": a duo's section, named by the start of its id and nothing else.
        public static func duo(_ shortID: String) -> String { "Duo \(shortID)" } // NEW COPY
        /// The subject of the export's mail: the existing bug report's subject with the
        /// approved name of the screen it came from. NEW COPY (a new composition).
        public static let mailSubject = "HydroDrop bug report: \(DuoCopy.diagnostics)"
    }

    // MARK: - The report

    public struct Field: Equatable, Sendable {
        public let label: String
        public let value: String
    }

    /// One recorded failure, every part already filtered.
    public struct ErrorLine: Equatable, Sendable {
        public let code: String
        public let http: String
        public let requestID: String
        public let at: String

        /// `code http id time`, as the export prints it.
        public var text: String { "\(code) \(http) \(requestID) \(at)" }
    }

    /// One response, every part already filtered.
    public struct RequestLine: Equatable, Sendable {
        public let status: String
        public let requestID: String
        public let at: String

        /// `status id time`, as the export prints it.
        public var text: String { "\(status) \(requestID) \(at)" }
    }

    public struct DuoSection: Equatable, Sendable {
        /// The first eight characters of the lowercase id. The full id never reaches the screen
        /// or the export: the report mail is the one place support is given it.
        public let shortID: String
        public let fields: [Field]
        public var title: String { Label.duo(shortID) }
    }

    public struct Report: Equatable, Sendable {
        /// `XXXX-XXXX-XXXX`, or nil when there is none worth showing (no `GET /me` answer yet,
        /// or a value that is not the contract's). The screen offers Copy only when it is set.
        public let supportID: String?
        /// Support ID, tier, app version, iOS version, availability, queued requests.
        public let summary: [Field]
        /// Enabled, time zone, window, last upload: what the last push upload said.
        public let notifications: [Field]
        public let duos: [DuoSection]
        /// Newest first, at most `DuoDiagnostics.keepErrors`.
        public let errors: [ErrorLine]
        /// Newest first, at most `DuoDiagnostics.keepRequests`.
        public let requests: [RequestLine]
    }

    /// The facts, filtered, in the order the screen draws them. `duos` is the ids of the duos
    /// on this phone, in the store's order; a duo with nothing recorded yet still gets its
    /// section, with dashes.
    public static func report(supportID: String?, tier: DuoTier?, appVersion: String, systemVersion: String,
                              availability: DuoAvailability, queuedOps: Int, diagnostics: DuoDiagnostics,
                              duos: [UUID]) -> Report {
        let support = shownSupportID(supportID, availability: availability)
        let summary = [
            Field(label: Label.supportID, value: support ?? Label.none),
            Field(label: Label.tier, value: tier.map(word(for:)) ?? Label.none),
            Field(label: Label.appVersion, value: plainVersion(appVersion) ?? Label.none),
            Field(label: Label.systemVersion, value: plainVersion(systemVersion) ?? Label.none),
            Field(label: Label.availability, value: word(for: availability)),
            Field(label: Label.queuedOps, value: String(queuedOps)),
        ]
        let notifications = [
            Field(label: Label.notificationsEnabled, value: diagnostics.lastUploadedEnabled.map { $0 ? Label.on : Label.off } ?? Label.none),
            Field(label: Label.timeZone, value: plainZone(diagnostics.lastUploadedZone) ?? Label.none),
            Field(label: Label.window, value: window(start: diagnostics.lastUploadedWindowStart, end: diagnostics.lastUploadedWindowEnd)),
            Field(label: Label.lastUpload, value: time(diagnostics.lastUploadAt)),
        ]
        let sections = duos.map { id -> DuoSection in
            let key = id.uuidString.lowercased()
            let entry = diagnostics.duos[key]
            return DuoSection(shortID: shortID(id), fields: [
                Field(label: Label.seq, value: entry.map { String($0.seq) } ?? Label.none),
                Field(label: Label.cursor, value: entry.map { String($0.cursor) } ?? Label.none),
                Field(label: Label.lastFetch, value: time(entry?.lastFetchAt)),
                Field(label: Label.lastWrite, value: time(entry?.lastWriteAt)),
                Field(label: Label.lastError, value: entry?.lastError.map { errorLine($0).text } ?? Label.none),
            ])
        }
        let errors = newestFirst(diagnostics.recentErrors, at: \.at).prefix(DuoDiagnostics.keepErrors).map(errorLine)
        let requests = newestFirst(diagnostics.recentRequests, at: \.at).prefix(DuoDiagnostics.keepRequests).map { record in
            RequestLine(status: httpStatus(record.status), requestID: requestID(record.requestID) ?? Label.none, at: time(record.at))
        }
        return Report(supportID: support, summary: summary, notifications: notifications, duos: sections,
                      errors: Array(errors), requests: Array(requests))
    }

    /// The export: the same facts as the screen, one per line, times in ISO 8601 UTC. The app
    /// puts its existing `Diagnostics.summary` above it; that header is the app's and is not
    /// built here (it needs UIKit).
    public static func text(supportID: String?, tier: DuoTier?, appVersion: String, systemVersion: String,
                            availability: DuoAvailability, queuedOps: Int, diagnostics: DuoDiagnostics,
                            duos: [UUID], now: Date, alreadySaid: [String] = []) -> String {
        text(report(supportID: supportID, tier: tier, appVersion: appVersion, systemVersion: systemVersion,
                    availability: availability, queuedOps: queuedOps, diagnostics: diagnostics, duos: duos),
             now: now, alreadySaid: alreadySaid)
    }

    /// The export of a report already made, so the screen's mail is built from the very report
    /// the screen drew. `alreadySaid` is the header's lines: the app's bug-report header already
    /// says "App version: …" and "iOS version: …", so the Duo facts' own two lines are printed
    /// only when they say something else (a Debug build's `-DuoClientVersion` override, which is
    /// what the Duo server is told). The screen keeps both.
    public static func text(_ report: Report, now: Date, alreadySaid: [String] = []) -> String {
        func fields(_ fields: [Field]) -> [String] { fields.map { "\($0.label): \($0.value)" } }
        let repeatable: Set<String> = [Label.appVersion, Label.systemVersion]
        let summary = fields(report.summary.filter { !(repeatable.contains($0.label) && alreadySaid.contains("\($0.label): \($0.value)")) })
        var lines = [Label.title, "\(Label.exportedAt): \(time(now))"] + summary
        lines += [""] + [Label.notifications] + fields(report.notifications)
        for duo in report.duos {
            lines += [""] + [duo.title] + fields(duo.fields)
        }
        lines += ["", Label.recentErrors] + (report.errors.isEmpty ? [Label.none] : report.errors.map(\.text))
        lines += ["", Label.recentRequests] + (report.requests.isEmpty ? [Label.none] : report.requests.map(\.text))
        return lines.joined(separator: "\n")
    }

    // MARK: - The filters

    /// The contract's `support_id` is `^[0-9A-HJKMNP-TV-Z]{12}$` (§3.7). Either that or the
    /// `XXXX-XXXX-XXXX` it is shown as comes back as the shown form; anything else is nil, so
    /// a value that is not a Support ID is never printed as one. (`DuoMemberInfo.supportIDDisplay`
    /// passes a value of the wrong length through unchanged, which is right for a label and
    /// wrong for a mail.)
    public static func displaySupportID(_ raw: String?) -> String? {
        guard var id = raw else { return nil }
        if id.count == 14 {
            let characters = Array(id)
            guard characters[4] == "-", characters[9] == "-" else { return nil }
            id.removeAll { $0 == "-" }
        }
        guard id.count == 12, id.allSatisfy({ crockford.contains($0) }) else { return nil }
        let characters = Array(id)
        return [characters[0..<4], characters[4..<8], characters[8..<12]].map { String($0) }.joined(separator: "-")
    }

    /// The Support ID the screen, the export and the report mail may show: none while the restore
    /// question is up. Until the person answers "Continue" or "Not me, start fresh", the identity
    /// in the Keychain may be the previous owner's (a phone restored from someone else's backup,
    /// §3.4), and their Support ID is theirs to give, not this person's (decision D76).
    public static func shownSupportID(_ raw: String?, availability: DuoAvailability) -> String? {
        if case .needsRestoreChoice = availability { return nil }
        return displaySupportID(raw)
    }

    /// The first eight characters of the lowercase id, as the screen names a duo.
    public static func shortID(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }

    /// One word per state, written out rather than interpolated: the restore question carries
    /// two names, which `"\(availability)"` would print. Plain words rather than the Swift case
    /// names, since a person reads them aloud to support. NEW COPY, every one.
    public static func word(for availability: DuoAvailability) -> String {
        switch availability {
        case .unknown: return "unknown" // NEW COPY
        case .available: return "available" // NEW COPY
        case .maintenance: return "maintenance" // NEW COPY
        case .upgradeRequired: return "update required" // NEW COPY
        case .disconnected: return "disconnected" // NEW COPY
        case .banned: return "banned" // NEW COPY
        case .needsRestoreChoice: return "restore question" // NEW COPY
        }
    }

    /// The tier, as `GET /me` names it (§11.2). NEW COPY, both.
    public static func word(for tier: DuoTier) -> String {
        switch tier {
        case .attested: return "attested" // NEW COPY
        case .low: return "low" // NEW COPY
        }
    }

    /// ISO 8601 in UTC, `2026-10-08T07:30:00Z`, whatever the phone's zone, calendar or locale,
    /// so support can line a time up with the server's logs without asking where the person is.
    public static func time(_ date: Date?) -> String {
        guard let date else { return Label.none }
        return date.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!))
    }

    private static let crockford = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// The codes `DuoDiagnostics.record` writes: the contract's, and its own three.
    private static let knownCodes = Set(DuoErrorCode.allCases.map(\.rawValue)).union(["offline", "unreadable", "other"])

    private static func errorLine(_ record: DuoDiagnostics.ErrorRecord) -> ErrorLine {
        ErrorLine(code: knownCodes.contains(record.code) ? record.code : Label.none,
                  http: record.http.map(httpStatus) ?? Label.none,
                  requestID: requestID(record.requestID) ?? Label.none,
                  at: time(record.at))
    }

    /// A status a response can have, 100 to 599; anything else is not one (a status 0 is the
    /// client's "no credential", and a defaults blob could hold a ten-digit number) and reads as
    /// a dash (D76).
    private static func httpStatus(_ status: Int) -> String {
        (100...599).contains(status) ? String(status) : Label.none
    }

    /// The only shape the Worker writes (`src/http/response.ts`): a `cf-ray`, 16 lowercase hex
    /// characters and an optional data-centre code, or 16 hex characters of its own. Only the 16
    /// hex characters are printed: the code names a city (`-LHR`), and support finds the request
    /// by the rest (D76). The shared filter (`DuoDiagnostics.usableRequestID`, used by the error
    /// sheet's `(ref ...)` line and the Duo screen's footer) is looser: it let a 43-character
    /// secret, a push token, a UUID, a dashed IP address and a name through, because whatever
    /// answers the request writes the header, a proxy the phone trusts included. So an id the
    /// error sheet shows can read as a dash here.
    private static func requestID(_ raw: String?) -> String? {
        guard let raw, raw.range(of: #"^[0-9a-f]{16}(-[A-Z]{3})?$"#, options: .regularExpression) != nil else { return nil }
        return String(raw.prefix(16))
    }

    /// Newest first by the time printed beside each line. The lists are kept newest first as
    /// they are written, so this changes nothing unless the phone's clock went back between two
    /// records; then the times shown still read in order. Ties keep their written order.
    private static func newestFirst<T>(_ items: [T], at: KeyPath<T, Date>) -> [T] {
        items.enumerated().sorted { lhs, rhs in
            let left = lhs.element[keyPath: at], right = rhs.element[keyPath: at]
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// `2.0 (57)` or `26.5`: digits, dots, spaces and brackets, as the bundle and UIKit write
    /// versions. Anything else is not a version.
    private static func plainVersion(_ version: String) -> String? {
        guard !version.isEmpty, version.count <= 32,
              version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == " " || $0 == "(" || $0 == ")") }) else { return nil }
        return version
    }

    /// An IANA zone this phone's Foundation knows, such as `Europe/London`.
    private static func plainZone(_ zone: String?) -> String? {
        guard let zone, !zone.isEmpty, zone.count <= 64,
              zone.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "/" || $0 == "_" || $0 == "-" || $0 == "+") }),
              TimeZone(identifier: zone) != nil else { return nil }
        return zone
    }

    /// `08:00-22:00` from the minutes after midnight the upload sent (`wake_start_min`,
    /// `wake_end_min`, 0 to 1439). A number out of range is printed as it is: it is only a
    /// number, and a wrong one is what Diagnostics is for. Sent only with notifications on,
    /// so off reads as a dash.
    private static func window(start: Int?, end: Int?) -> String {
        guard let start, let end else { return Label.none }
        func clock(_ minutes: Int) -> String {
            guard (0..<1440).contains(minutes) else { return String(minutes) }
            return String(format: "%02d:%02d", minutes / 60, minutes % 60)
        }
        return "\(clock(start))-\(clock(end))"
    }
}

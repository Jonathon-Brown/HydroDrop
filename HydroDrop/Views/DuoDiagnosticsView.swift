#if DUO_V2
import MessageUI
import SwiftUI
import UIKit

/// Settings > Duo Streaks > Diagnostics (final design §10.8), pushed from the Duo screen: the
/// Support ID with a Copy button, the tier, the versions, the service's state, the op queue,
/// the last push upload, each duo's sync position and last error, the last five errors and the
/// last ten responses, and Export diagnostics, which opens a mail with all of it for the person
/// to send or not.
///
/// What it draws is `DuoDiagnosticsExport.report`, the same report the export prints, so the
/// screen and the mail cannot say different things, and both hold only ids, numbers, error
/// codes and UTC times. It sends nothing: no request on appear (it does not even refresh, since
/// what it shows is what the phone already knows), and Export only opens the mail composer, or
/// a `mailto:` link where Mail has no account, as the bug report does. A duo is named by the
/// first eight characters of its id; the full id goes only into the report mail, where support
/// needs it.
struct DuoDiagnosticsView: View {
    @ObservedObject var duoStore: DuoStore
    private let route: MMailRoute
    private let pasteboard: UIPasteboard
    /// The export in the composer, made at the tap, so the mail holds what the screen said at that
    /// moment. The sheet is presented by this value (`sheet(item:)`): its content used to read a
    /// separate `@State` string, which a first presentation can see before the update lands.
    @State private var composing: MMail?
    @State private var showingNoMailAlert = false

    static let mExportID = "duo.diagnostics.export"
    static let mSupportIDRowID = "duo.diagnostics.supportid"
    static let mCopyID = "duo.diagnostics.supportid.copy"

    /// `route` and `pasteboard` are the system's; a test hands in its own, since it can drive
    /// neither Mail nor `UIApplication.open` in the simulator and must not touch the real pasteboard.
    init(duoStore: DuoStore, route: MMailRoute = .system, pasteboard: UIPasteboard = .general) {
        _duoStore = ObservedObject(wrappedValue: duoStore)
        self.route = route
        self.pasteboard = pasteboard
    }

    var body: some View {
        let report = Self.mReport(for: duoStore)
        List {
            Section {
                ForEach(report.summary, id: \.label) { field in
                    switch field.label {
                    case DuoDiagnosticsExport.Label.supportID:
                        MSupportIDRow(supportID: report.supportID) { Self.mCopySupportID(from: duoStore, to: pasteboard) }
                    case DuoDiagnosticsExport.Label.queuedOps:
                        // The op queue publishes nothing, so its length used to change on screen only
                        // when something else did. It is read again every second while the screen is
                        // open: a pure read of the queue from the defaults, no request.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            MFieldRow(field: Self.mReport(for: duoStore).summary.first { $0.label == field.label } ?? field)
                        }
                    default:
                        MFieldRow(field: field)
                    }
                }
            }

            Section {
                Button(DuoCopy.exportDiagnostics) { export() }
                    .accessibilityIdentifier(Self.mExportID)
            }

            Section {
                ForEach(report.notifications, id: \.label) { MFieldRow(field: $0) }
            } header: {
                MHeader(text: DuoDiagnosticsExport.Label.notifications)
            }

            // Two duos could share the first eight characters of their ids, so the sections are
            // told apart by their place, not by what they show.
            ForEach(Array(report.duos.enumerated()), id: \.offset) { _, duo in
                Section {
                    ForEach(duo.fields, id: \.label) { MFieldRow(field: $0) }
                } header: {
                    MHeader(text: duo.title)
                }
            }

            Section {
                if report.errors.isEmpty {
                    MNoneRow()
                } else {
                    ForEach(Array(report.errors.enumerated()), id: \.offset) { _, line in MErrorRow(line: line) }
                }
            } header: {
                MHeader(text: DuoDiagnosticsExport.Label.recentErrors)
            }

            Section {
                if report.requests.isEmpty {
                    MNoneRow()
                } else {
                    ForEach(Array(report.requests.enumerated()), id: \.offset) { _, line in MRequestRow(line: line) }
                }
            } header: {
                MHeader(text: DuoDiagnosticsExport.Label.recentRequests)
            }
        }
        .navigationTitle(DuoCopy.diagnostics)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $composing) { mail in
            route.composer(mail) { _ in composing = nil }
        }
        // The bug report's own alert, word for word, for a phone with no mail app to hand.
        .alert("No Mail Account Set Up", isPresented: $showingNoMailAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Set up Mail on this device, or email \(DuoReportMail.recipient) directly.")
        }
    }

    /// The composer if Mail has an account, else a `mailto:` link for whichever mail app the
    /// person uses, else the bug report's alert: `BugReportView`'s order, except that a link
    /// nothing could open now says so instead of doing nothing. The screen stays where it is (the
    /// bug report closes its sheet; this is a pushed page with more to read). Nothing is sent
    /// here, and the export is never logged.
    private func export() {
        let mail = Self.mExportMail(for: duoStore, now: Date())
        if route.canCompose() {
            composing = mail
        } else if let url = mail.mailtoURL {
            route.open(url) { opened in
                if !opened { showingNoMailAlert = true }
            }
        } else {
            showingNoMailAlert = true
        }
    }

    // MARK: - What the screen is drawn from (static, so a test can ask without drawing it)

    /// The store's facts as the screen and the export show them. Only typed facts go in: the
    /// Support ID string is checked against the contract's shape inside, and the availability
    /// becomes a word, so the restore question's two names never get near the report.
    @MainActor
    static func mReport(for store: DuoStore, systemVersion: String = UIDevice.current.systemVersion) -> DuoDiagnosticsExport.Report {
        DuoDiagnosticsExport.report(supportID: store.memberInfo?.supportID, tier: store.memberInfo?.tier,
                                    appVersion: DuoConfig.client.appVersion, systemVersion: systemVersion,
                                    availability: store.availability, queuedOps: store.queuedOpCount,
                                    diagnostics: store.diagnostics, duos: store.duos.map(\.id))
    }

    /// The mail's body: the app's existing bug-report header (`Diagnostics.summary`: app version,
    /// iOS version, device model), then the Duo facts, which leave out their own app and iOS
    /// version lines when the header already says the same.
    @MainActor
    static func mExportBody(for store: DuoStore, now: Date) -> String {
        let header = Diagnostics.summary
        return header + "\n\n" + DuoDiagnosticsExport.text(mReport(for: store), now: now, alreadySaid: header.components(separatedBy: "\n"))
    }

    /// The export's mail: to support, with the bug report's subject and the screen's name.
    @MainActor
    static func mExportMail(for store: DuoStore, now: Date) -> MMail {
        MMail(recipient: DuoReportMail.recipient, subject: DuoDiagnosticsExport.Label.mailSubject, body: mExportBody(for: store, now: now))
    }

    /// Copy puts the shown form, `XXXX-XXXX-XXXX`, on the pasteboard, and does nothing when there
    /// is no Support ID to show (the button is not drawn then either): before `GET /me` has
    /// answered, and while the restore question is up (D76).
    @MainActor
    static func mCopySupportID(from store: DuoStore, to pasteboard: UIPasteboard = .general) {
        guard let supportID = mReport(for: store).supportID else { return }
        pasteboard.string = supportID
    }
}

// MARK: - Rows

/// The Support ID and its Copy button. The row is a container (`duo.diagnostics.supportid`) of
/// two elements: "Support ID, ABCD-1234-EFGH", and Copy as a button of its own
/// (`duo.diagnostics.supportid.copy`). It used to be one combined element, which folded Copy into
/// the row so neither VoiceOver nor a UI test could reach it on its own. At the accessibility
/// text sizes Copy goes under the id: beside it, the label and the id each broke over three lines.
private struct MSupportIDRow: View {
    let supportID: String?
    let copy: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: DuoDiagnosticsExport.Label.supportID)
                Text(verbatim: supportID ?? DuoDiagnosticsExport.Label.none)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if !stacked { Spacer(minLength: 0) }
            if supportID != nil {
                Button("Copy", action: copy) // NEW COPY
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(DuoDiagnosticsView.mCopyID)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(DuoDiagnosticsView.mSupportIDRowID)
    }
}

/// A label and its value, side by side, or one above the other at the accessibility text sizes,
/// where side by side would squeeze a request id or a date into a column a few letters wide.
private struct MFieldRow: View {
    let field: DuoDiagnosticsExport.Field
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(verbatim: field.label)
            if !stacked { Spacer(minLength: 0) }
            Text(verbatim: field.value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(stacked ? .leading : .trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One recorded failure: its code and HTTP status, its request id (selectable, to quote), and when.
private struct MErrorRow: View {
    let line: DuoDiagnosticsExport.ErrorLine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(line.code) \(line.http)")
                .fontDesign(.monospaced)
            Text(verbatim: line.requestID)
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(verbatim: line.at)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// One response: its status and request id, and when.
private struct MRequestRow: View {
    let line: DuoDiagnosticsExport.RequestLine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(line.status) \(line.requestID)")
                .fontDesign(.monospaced)
                .textSelection(.enabled)
            Text(verbatim: line.at)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// An empty list reads as a dash rather than as a heading with nothing under it.
private struct MNoneRow: View {
    var body: some View {
        Text(verbatim: DuoDiagnosticsExport.Label.none)
            .foregroundStyle(.secondary)
    }
}

/// A section's heading, in the case it is written in: a duo's section is named by the start of
/// its lowercase id, which the list's default upper-casing would turn into something else.
private struct MHeader: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .textCase(nil)
    }
}
#endif

import SwiftUI
import MessageUI

struct BugReportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var showingMailCompose = false
    @State private var showingNoMailAlert = false
    @State private var showingSentConfirmation = false

    private let supportEmail = "brownjonathon943@gmail.com"

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emailBody: String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = trimmed.isEmpty ? "(no description provided)" : trimmed
        return details + "\n\n" + Diagnostics.summary
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What went wrong?") {
                    TextField("Short summary", text: $title)
                }
                Section("Details") {
                    TextEditor(text: $description)
                        .frame(minHeight: 120)
                }
                Section {
                    Text(Diagnostics.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Included automatically")
                } footer: {
                    Text("This helps track down the issue faster.")
                }
            }
            .navigationTitle("Report a Bug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .disabled(!canSubmit)
                }
            }
            .sheet(isPresented: $showingMailCompose) {
                MailComposeView(
                    recipient: supportEmail,
                    subject: "HydroDrop bug report: \(title)",
                    body: emailBody
                ) { result in
                    showingMailCompose = false
                    if result == .sent { showingSentConfirmation = true }
                }
            }
            .alert("No Mail Account Set Up", isPresented: $showingNoMailAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Set up Mail on this device, or email \(supportEmail) directly.")
            }
            .alert("Thanks!", isPresented: $showingSentConfirmation) {
                Button("OK") { dismiss() }
            } message: {
                Text("Your bug report was sent.")
            }
        }
    }

    private func send() {
        if MFMailComposeViewController.canSendMail() {
            showingMailCompose = true
        } else if let url = mailtoURL() {
            UIApplication.shared.open(url)
            dismiss()
        } else {
            showingNoMailAlert = true
        }
    }

    private func mailtoURL() -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "HydroDrop bug report: \(title)"),
            URLQueryItem(name: "body", value: emailBody)
        ]
        return components.url
    }
}

#Preview {
    BugReportView()
}

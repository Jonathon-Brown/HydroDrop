import Foundation

// The pure rules of the launch sequence (final design §3.4): which launch this one is, and
// whether the person must be asked "This phone was connected to a duo with <partner>. Continue
// as <name>?" before anything else is sent. The app's `DuoIdentity` reads the Keychain and the
// install's files and talks to the server; everything it decides with what it read is here, so
// the Android app and a test can hold it to the same answers without a Keychain or a network.

public enum DuoLaunchDecision {
    public enum Launch: Equatable, Sendable {
        /// No credential: no identity. Nothing is sent until a Create, Join or Reconnect tap (§3.1).
        case none
        /// A credential, this phone's marker, and an install that settled its restore question:
        /// an ordinary launch. Nothing is sent here; `GET /me` is the sync engine's to ask.
        case normal
        /// A credential without the marker: the credential came from another phone (Quick
        /// Start, an iCloud or encrypted backup restored onto a new phone). It is rotated, once,
        /// so any other holder of the same secret is locked out, the marker is written at once,
        /// and `GET /me` then decides whether to ask.
        case restored
        /// A credential and its marker, but this install never settled: a reinstall on the same
        /// phone (the Keychain outlives the app, the install's files do not), including a phone
        /// sold with the app deleted but not erased, or a restore interrupted after its rotate.
        /// Not rotated: a rotate cannot safely be repeated (the contract's rotate is not
        /// idempotent, and an answer lost on the way back leaves the phone holding a revoked
        /// secret). `GET /me` is read and the question asked again, so the duos of whoever owned
        /// the credential are never adopted without a yes (SEC F21).
        case unsettled
    }

    /// The marker is `ThisDeviceOnly` and the credential is not, so the credential can arrive on
    /// a phone the marker never reaches. "Settled" is a file excluded from backup, so it never
    /// arrives by restore and does not outlive a reinstall. A marker or a settled file without a
    /// credential belongs to an identity that was discarded and has nothing to launch.
    public static func decide(hasCredential: Bool, hasMarker: Bool, isSettled: Bool) -> Launch {
        guard hasCredential else { return .none }
        guard hasMarker else { return .restored }
        return isSettled ? .normal : .unsettled
    }

    /// The question to ask after a restore or a reinstall, or nil when there is nothing to ask:
    /// the server lists no duo this build can hold, or this phone already holds duos of its own
    /// (a backup that carried the cache along, which the person plainly meant to keep).
    ///
    /// The caller passes `me` with the duos the person cleared already taken out, since a Clear
    /// is remembered only on the phone (§12.2) and a cleared duo must not be offered. A listed
    /// duo whose id is not a UUID is one `DuoMapping.duo(from:previous:now:)` cannot make into a
    /// card, so it is not one to ask about either: "Continue" would seed nothing.
    ///
    /// The partner is named from the duo the person is most likely to recognise: the first active
    /// one, else the first waiting for its partner, else the first listed at all (an ended duo
    /// the server still lists for 30 days, whose names a header-only view may mask). The partner
    /// is that duo's other member: the partner's name when this member owns it, the owner's when
    /// this member joined it. My name is the member's own. Either may be nil, and the screen that
    /// asks says so in its own words.
    public static func restorePrompt(from me: DuoWireGetMeResponse, cachedDuoCount: Int) -> DuoRestorePrompt? {
        guard cachedDuoCount == 0 else { return nil }
        let holdable = me.duos.filter { UUID(uuidString: $0.id) != nil }
        guard let named = holdable.first(where: { $0.state == .active })
            ?? holdable.first(where: { $0.state == .pending })
            ?? holdable.first else { return nil }
        let partnerName = named.myRole == .owner ? named.partnerDisplayName : named.ownerDisplayName
        return DuoRestorePrompt(partnerName: partnerName, myName: me.member.displayName)
    }
}

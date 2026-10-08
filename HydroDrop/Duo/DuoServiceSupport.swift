#if DUO_V2
import Foundation

/// What every service does with a failed request, once, so the Duo screen says the same thing
/// whichever service met the failure (final design §6.7's "Client behaviour" column).
extension DuoDependencies {
    /// Whether the stored credential is the throwaway a Reconnect minted and has not finished
    /// with. It belongs to nobody who has a duo yet, so it cannot send a leave or a block for the
    /// duos cached on the phone (they are another member's: the server answers 404 and the exit
    /// would count as done), and a Reconnect, which is what finishes it, must not be refused
    /// because of such an exit.
    var credentialIsAThrowaway: Bool {
        guard let marked = cache.throwawayDeviceID else { return false }
        return identity?.credential?.deviceID == marked
    }

    /// Notes a failure: writes it to Diagnostics, and acts on what it says about this phone's
    /// standing: a 401 `unauthenticated` forgets the identity (a new one is made on the next
    /// Create or Join tap, never silently, §3.4); `device_revoked`, 426 and `banned` change what
    /// the screen offers; a 503 says the service is paused. Returns the verdict so the caller
    /// can decide what to do next. It never shows an alert: the caller says it in words.
    @discardableResult
    func noteFailure(_ error: Error, duoID: UUID? = nil) -> DuoRetry.Verdict {
        // A cancelled task is not a failure of the request, so it leaves nothing in Diagnostics
        // and changes nothing about this phone's standing. The caller still gets the retry.
        if error is CancellationError { return DuoRetry.verdict(for: error) }
        host.diagnostics.record(error, duoID: duoID, now: clock.now)
        let verdict = DuoRetry.verdict(for: error)
        switch verdict {
        case .reidentify:
            // The attestation key belongs to the device id the server just forgot, and
            // `discard()` takes the credential that names it, so the id is read first.
            if let deviceID = identity.credential?.deviceID { attester.forgetKeys(forDevice: deviceID) }
            identity.discard()
            host.availability = .available
            abandonLiveDuos()
            // The person asked to delete everything and the answer to that request never came:
            // the identity being gone is the answer, so finish the wipe instead of leaving the
            // cards, the name and the orphan Keychain items behind with no way to remove them.
            if cache.deleteRequestedAt != nil { exiting?.startFresh() }
        case .disconnected:
            host.availability = .disconnected
        case .upgradeRequired:
            host.availability = .upgradeRequired
        case .banned:
            host.availability = .banned
        case .termsRequired:
            // A terms version newer than this build knows (the server's was raised) cannot be
            // accepted here: Accept would record the built-in version and be refused again,
            // for ever. That is an app that needs updating, not a sheet to show.
            if let served = (error as? DuoTransportError)?.context?.details?.termsVersion, served > DuoProtocolConstants.termsVersion {
                host.availability = .upgradeRequired
            } else {
                host.needsTerms = true
            }
        case .retry:
            if case .maintenance = error as? DuoTransportError { host.availability = .maintenance }
        case .ended, .fail, .cancelled:
            break
        }
        return verdict
    }

    /// The server no longer knows this phone's identity (401 `unauthenticated`: `DELETE /me` from
    /// another copy, say), so every live duo here has lost its seat and nothing can ever be sent
    /// for it again: the client throws `unauthenticated` without a credential. Left as they
    /// were, the cards would stay live with a Nudge that does nothing and Delete my Duo data
    /// hidden (no credential), with nothing to say why. They end locally with `ended_by = unknown`
    /// and no alert, as for `duo_unknown` (§6.7), so the person can Clear them. Whatever was made
    /// with the dead credential goes too: queued requests and in-flight records (a replay could
    /// only answer 401), link secrets (their codes are void) and the push upload record (the
    /// token row belonged to the device the server forgot). So does the record of the member
    /// who was forgotten, since `GET /me`'s answer (the Support ID, the name, the old tier and
    /// the device list) is about someone who no longer exists, and so does the list of devices
    /// the person was told about: left behind, it made this phone's own new device look like an
    /// added one (D45) the next time the person started again.
    private func abandonLiveDuos() {
        let now = clock.now
        for duo in host.duos where !duo.hasEnded {
            host.update(duo.id) {
                $0.endedAt = now
                $0.endedBy = .unknown
                $0.pendingOp = nil
                $0.invite = nil
                $0.openInviteExpiresAt = nil
            }
        }
        for duo in host.duos { try? secrets.deleteLinkSecret(forDuo: duo.id) }
        ops?.discardAll()
        cache.saveInflight(DuoInflightJournal())
        cache.savePushUpload(nil)
        host.memberInfo = nil
        host.newDeviceNotice = false
        cache.forgetSeenDeviceIDs()
    }

    /// A request went through: a service that was paused is not any more.
    func noteSuccess() {
        switch host.availability {
        case .unknown, .maintenance: host.availability = .available
        default: break
        }
    }

    /// The person's own name for the next request: cleaned, and nil when nothing is left.
    func cleanedNameOrNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = DuoState.cleanedName(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The rows to send with a create or a join: what the log says about the last week, as the
    /// outbox computes it, every one at `base_ver` 0 since a duo being made or joined has no
    /// rows to compare against (§6.3, §7.1).
    func firstRows(role: DuoRole, now: Date) -> [DuoWireStatusIn] {
        guard let latest = host.latest else { return [] }
        let coverage = [identity.installDay, latest.earliestEntryDay].compactMap { $0 }.min() ?? DuoOutbox.coveredForever
        return DuoOutbox.unsent(role: role, totalsByDay: latest.totalsByDay, goalML: latest.goalML, known: [], myToday: clock.today,
                                now: now, coverageStart: coverage, calendar: clock.calendar)
            .map { DuoWireStatusIn(day: $0.day, goalMet: $0.goalMet, progressBucket: $0.progressBucket, baseVer: 0) }
    }
}
#endif

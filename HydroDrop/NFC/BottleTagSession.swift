import CoreNFC
import Foundation

/// The one place HydroDrop talks to an NFC sticker: writing a bottle's address onto
/// one, and reading one back while the app is open.
///
/// Reading a sticker with the app closed needs none of this. iOS reads the tag itself
/// and opens the universal link, which arrives through `AppRouter` like any other tap.
/// The scanner here is the fallback for phones and moments where that does not happen,
/// and it hands what it reads to exactly the same place.
///
/// App target only. There is no NFC on the watch and none in a widget.
final class BottleTagSession: NSObject {
    static let shared = BottleTagSession()

    /// False on the simulator, on an iPad, and on any phone without an NFC reader. All
    /// of the NFC interface is hidden when this is false, rather than shown and broken.
    static var isAvailable: Bool { NFCNDEFReaderSession.readingAvailable }

    /// Whether any of the bottle tag interface should be on screen. The same answer as
    /// `isAvailable` everywhere that matters; the launch argument exists only so the
    /// screens can be looked at on a simulator, which has no NFC, and is compiled out
    /// of Release.
    static var showsInterface: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ShowBottleUI") { return true }
        #endif
        return isAvailable
    }

    private enum Job {
        case write(URL, bottleName: String)
        case scan((URL) -> Void)
    }

    // Only ever touched on the main queue, which is the queue the session is given.
    private var session: NFCNDEFReaderSession?
    private var job: Job?

    private override init() { super.init() }

    /// Writes `bottleID`'s address to the next sticker held to the phone.
    func writeTag(for bottleID: UUID, bottleName: String) {
        begin(
            .write(BottleTag.url(for: bottleID), bottleName: bottleName),
            prompt: "Hold the top of your iPhone near the sticker."
        )
    }

    /// Reads the next sticker held to the phone and hands back the address on it.
    func scan(onAddress: @escaping (URL) -> Void) {
        begin(.scan(onAddress), prompt: "Hold the top of your iPhone near your bottle's sticker.")
    }

    private func begin(_ job: Job, prompt: String) {
        guard Self.isAvailable else { return }
        session?.invalidate()
        self.job = job
        // Not invalidated after the first read: a write needs the session to stay open
        // past detection, and a scan closes it by hand once it has what it came for.
        let session = NFCNDEFReaderSession(delegate: self, queue: .main, invalidateAfterFirstRead: false)
        session.alertMessage = prompt
        self.session = session
        session.begin()
    }

    private func finish(_ session: NFCNDEFReaderSession, saying message: String) {
        session.alertMessage = message
        session.invalidate()
    }

    private func fail(_ session: NFCNDEFReaderSession, saying message: String) {
        session.invalidate(errorMessage: message)
    }
}

extension BottleTagSession: NFCNDEFReaderSessionDelegate {
    func readerSessionDidBecomeActive(_ session: NFCNDEFReaderSession) {}

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        // Fires for a cancel and a timeout as well as for a real failure. The sheet the
        // system shows has already told the person whichever it was.
        if self.session === session {
            self.session = nil
            job = nil
        }
    }

    /// Required by the protocol, but never called while `didDetect tags` is implemented.
    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {}

    func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]) {
        guard let job else { return }
        guard tags.count == 1, let tag = tags.first else {
            session.alertMessage = "More than one tag is in range. Try with just one."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { session.restartPolling() }
            return
        }

        session.connect(to: tag) { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.fail(session, saying: "That did not work. Hold still a little longer and try again.")
                return
            }
            switch job {
            case .write(let address, let bottleName):
                self.write(address, bottleName: bottleName, to: tag, in: session)
            case .scan(let onAddress):
                self.read(tag, in: session, onAddress: onAddress)
            }
        }
    }

    private func write(_ address: URL, bottleName: String, to tag: NFCNDEFTag, in session: NFCNDEFReaderSession) {
        tag.queryNDEFStatus { [weak self] status, capacity, error in
            guard let self else { return }
            guard error == nil else {
                self.fail(session, saying: "That tag could not be read. Try another one.")
                return
            }
            guard let payload = NFCNDEFPayload.wellKnownTypeURIPayload(url: address) else {
                self.fail(session, saying: "That did not work. Please try again.")
                return
            }
            let message = NFCNDEFMessage(records: [payload])

            switch status {
            case .readWrite:
                guard message.length <= capacity else {
                    self.fail(session, saying: "This tag is too small. NTAG213 or larger works.")
                    return
                }
                tag.writeNDEF(message) { error in
                    if error != nil {
                        self.fail(session, saying: "The tag moved away too soon. Try again and hold still.")
                    } else {
                        self.finish(session, saying: "Done. Tap this tag any time to log \(bottleName).")
                    }
                }
            case .readOnly:
                self.fail(session, saying: "This tag is locked, so it cannot be written.")
            case .notSupported:
                self.fail(session, saying: "This kind of tag will not work. NTAG213 or NTAG215 stickers do.")
            @unknown default:
                self.fail(session, saying: "This kind of tag will not work. NTAG213 or NTAG215 stickers do.")
            }
        }
    }

    private func read(_ tag: NFCNDEFTag, in session: NFCNDEFReaderSession, onAddress: @escaping (URL) -> Void) {
        tag.readNDEF { [weak self] message, _ in
            guard let self else { return }
            let address = message?.records.lazy.compactMap { $0.wellKnownTypeURIPayload() }.first
            // Whether the bottle is known is decided by the same code that handles a tap
            // from outside the app, not here. This only checks the tag is one of ours.
            guard let address, BottleTag.tagID(from: address) != nil else {
                self.fail(session, saying: "That is not a HydroDrop bottle tag.")
                return
            }
            self.finish(session, saying: "Got it.")
            onAddress(address)
        }
    }
}

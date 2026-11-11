#if DUO_V2
// The session is handed to a serial queue to configure, start and stop, which AVFoundation's own
// docs prescribe; its types predate Sendable.
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

// The in-app QR scanner of the code-entry sheet (final design §4.1: "both apps have an in-app
// scanner (AVFoundation)"), and nowhere else.
//
// What the camera may do here is narrower than what AVFoundation allows, because the camera
// usage string promises it ("HydroDrop uses the camera only to scan a duo invite's QR code. The
// picture is never saved or sent.") and the privacy review of stage O holds the code to that
// sentence:
// - the session gets one input, the camera, and one output, a metadata output that reads QR
//   codes and nothing else. No photo, video-frame or movie output is ever added, nothing is
//   drawn out of the preview, and nothing goes through Vision or VisionKit, so no picture
//   exists anywhere the app could keep or send one. `DuoLiveQRCapture.configure` is the one
//   place a session is given anything, and the tests fail if it adds any other output;
// - the permission is asked for only when the person taps Scan (the sheet, not this file);
// - the session stops and is let go when the scanner leaves the screen, when a code is read,
//   when the person goes back to typing, when the app goes to the background and when the
//   system interrupts it (iPad Split View, a call);
// - a payload is never logged and never kept: it is read by `DuoCodeEntryModel.scan` and only
//   the invite it holds (the code and the link's secret) goes on, to the pending invite.
//
// The session sits behind `DuoQRCapturing` so the scanner's rules can be tested on a simulator,
// which has no camera, with a fake in its place.

// MARK: - The permission

/// The camera's permission and presence, behind a protocol so a test can say what they are and
/// count what the sheet asked. Reading either property asks the person nothing; only
/// `requestAccess()` brings up the system's question.
protocol DuoCameraAuthorizing: Sendable {
    /// Whether this phone has a camera at all (the simulator has none).
    var hasCamera: Bool { get }
    /// `AVAuthorizationStatus.rawValue`, which `DuoCameraAccess.from(rawStatus:hasCamera:)` reads.
    var rawStatus: Int { get }
    /// Shows the system's camera question and answers whether the person allowed it.
    func requestAccess() async -> Bool
}

struct DuoLiveCameraAuthorization: DuoCameraAuthorizing {
    var hasCamera: Bool { AVCaptureDevice.default(for: .video) != nil }
    var rawStatus: Int { AVCaptureDevice.authorizationStatus(for: .video).rawValue }
    func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }
}

// MARK: - The capture session

/// Why a camera that was started stopped on its own.
enum DuoQRCaptureEnd: Equatable {
    /// It never started: no camera, one another app holds, or a session that refused it.
    case couldNotStart
    /// The system took it away (iPad Split View, a call), which freezes the preview with no word.
    case interrupted
}

/// What the scanner needs of a camera: start it and be told each QR payload it reads, a layer
/// that shows what it sees, word when it stops on its own, and a way to stop it for good.
@MainActor
protocol DuoQRCapturing: AnyObject {
    /// The live preview, once started. Shown, never read back.
    var previewLayer: CALayer? { get }
    /// Starts reading. The camera is set up off the main thread, so a camera that cannot start
    /// says so later, through `ended`; so does one the system interrupts. Nothing is held after
    /// `ended` is called.
    func start(delivering payload: @escaping @MainActor (String) -> Void, ended: @escaping @MainActor (DuoQRCaptureEnd) -> Void)
    /// Stops reading and lets the session go. Safe to call more than once.
    func stop()
}

/// The real session: the back camera into one `AVCaptureMetadataOutput` set to `.qr`.
@MainActor
final class DuoLiveQRCapture: NSObject, DuoQRCapturing, AVCaptureMetadataOutputObjectsDelegate {
    /// The only kind of code the output is asked to read.
    nonisolated static let readsOnly: [AVMetadataObject.ObjectType] = [.qr]

    private var session: AVCaptureSession?
    private var preview: AVCaptureVideoPreviewLayer?
    private var deliver: (@MainActor (String) -> Void)?
    private var ended: (@MainActor (DuoQRCaptureEnd) -> Void)?
    private var interruptionObserver: NSObjectProtocol?
    /// Setting up the input, `startRunning` and `stopRunning` block until the camera has moved,
    /// so they run here rather than on the main thread. A serial queue keeps a stop behind the
    /// start it follows.
    private let sessionQueue = DispatchQueue(label: "us.hydrodrop.duo.qr-session")

    var previewLayer: CALayer? { preview }

    /// Whether a session is held right now, for the test that a failed start keeps nothing.
    var isHoldingSession: Bool { session != nil }

    func start(delivering payload: @escaping @MainActor (String) -> Void, ended: @escaping @MainActor (DuoQRCaptureEnd) -> Void) {
        guard session == nil else { return }
        let session = AVCaptureSession()
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        self.session = session
        self.preview = preview
        deliver = payload
        self.ended = ended
        // On iPad in Split View, or during a call, the system takes the camera away and the preview
        // freezes with nothing said; the scanner stops instead and the sheet goes back to the field.
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                                                     object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(.interrupted) }
        }
        let delegate: AVCaptureMetadataOutputObjectsDelegate = self
        sessionQueue.async { [weak self] in
            if let input = Self.backCameraInput(), Self.configure(session, input: input, delegate: delegate) {
                session.startRunning()
            } else {
                Self.release(session)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.end(.couldNotStart) } }
            }
        }
    }

    /// The camera stopped on its own: let it go and say why, once.
    private func end(_ reason: DuoQRCaptureEnd) {
        guard session != nil else { return }
        let ended = self.ended
        stop()
        ended?(reason)
    }

    func stop() {
        deliver = nil
        ended = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        preview?.session = nil
        preview?.removeFromSuperlayer()
        preview = nil
        guard let session else { return }
        self.session = nil
        sessionQueue.async { Self.release(session) }
    }

    // A safety net: a capture that is dropped without `stop()` still lets its camera go.
    deinit {
        if let session { sessionQueue.async { Self.release(session) } }
    }

    /// The back camera as an input, or nil without one. Called on the session queue: creating an
    /// input wakes the camera, which takes long enough to stall the main thread.
    private nonisolated static func backCameraInput() -> AVCaptureDeviceInput? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        // A QR code is held close to the lens; asking the focus to favour near things reads it
        // sooner. It changes nothing about what is captured, and a camera that cannot is left be.
        if device.isAutoFocusRangeRestrictionSupported, (try? device.lockForConfiguration()) != nil {
            device.autoFocusRangeRestriction = .near
            device.unlockForConfiguration()
        }
        return input
    }

    /// The one place a session is given anything: the input it is handed, if any, and a single
    /// metadata output reading QR codes alone, whose answers come on the main queue. Nothing else
    /// is ever added to a session in this file, which a test holds it to by looking at the outputs
    /// it leaves. False when the session cannot read QR codes, and then it must not be started.
    @discardableResult
    nonisolated static func configure(_ session: AVCaptureSession, input: AVCaptureInput?, delegate: AVCaptureMetadataOutputObjectsDelegate) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let input {
            guard session.canAddInput(input) else { return false }
            session.addInput(input)
        }
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        // The main queue, because the delegate below hops onto the main actor by assuming it.
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        // The types an output offers depend on the input it is joined to, so they are asked only
        // now; setting a type it does not offer would throw.
        guard let types = typesToRead(available: output.availableMetadataObjectTypes) else { return false }
        output.metadataObjectTypes = types
        return true
    }

    /// The types to ask an output for, given what it offers: QR codes alone, or nil when it cannot
    /// read them (a session with no camera offers nothing).
    nonisolated static func typesToRead(available: [AVMetadataObject.ObjectType]) -> [AVMetadataObject.ObjectType]? {
        readsOnly.allSatisfy(available.contains) ? readsOnly : nil
    }

    /// Stops a session and takes everything out of it, so the camera is free and nothing of it
    /// stays reachable. `stopRunning` is called whatever `isRunning` says: an interrupted session
    /// says it is not running and would otherwise resume when the interruption ends.
    nonisolated static func release(_ session: AVCaptureSession) {
        session.stopRunning()
        session.beginConfiguration()
        session.outputs.forEach(session.removeOutput)
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
    }

    /// The payloads of the QR codes among what an output read, in order; anything else is dropped.
    nonisolated static func qrPayloads(_ read: [(type: AVMetadataObject.ObjectType, text: String?)]) -> [String] {
        read.compactMap { $0.type == .qr ? $0.text : nil }
    }

    // The delegate is handed the main queue in `configure`, so this runs on the main thread.
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let payloads = Self.qrPayloads(metadataObjects.map { (type: $0.type, text: ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue) })
        guard !payloads.isEmpty else { return }
        MainActor.assumeIsolated {
            for payload in payloads { deliver?(payload) }
        }
    }
}

// MARK: - The scanner's rules

/// What the scanner does with a camera, apart from drawing: starts it, takes the first payload
/// that reads as a duo link and ignores every frame after it, ignores anything that is not one
/// without a word, and stops the camera whenever the scanner is done with it. A plain class, so a
/// test drives it with a fake camera.
@MainActor
final class DuoQRScanController {
    private var capture: DuoQRCapturing?
    private let notificationCenter: NotificationCenter
    private let succeeded: @MainActor () -> Void
    private var backgroundObserver: NSObjectProtocol?
    /// A code has been read: the scanner is finished, and later frames are ignored.
    private(set) var hasRead = false

    /// The code that was read, once at most, after the camera has stopped. Answers whether the
    /// sheet took it; the success haptic plays only then.
    var onInvite: (DuoParsedInvite) -> Bool
    /// The scanner stopped without reading a code, with the line the sheet should then show: the
    /// camera could not start or was taken away (a line saying so), or the app went to the
    /// background (none). The sheet goes back to typing rather than show a dead preview.
    var onClosed: (DuoCodeEntryModel.CameraLine) -> Void

    init(capture: DuoQRCapturing, notificationCenter: NotificationCenter = .default,
         succeeded: @escaping @MainActor () -> Void = { UINotificationFeedbackGenerator().notificationOccurred(.success) },
         onInvite: @escaping (DuoParsedInvite) -> Bool, onClosed: @escaping (DuoCodeEntryModel.CameraLine) -> Void) {
        self.capture = capture
        self.notificationCenter = notificationCenter
        self.succeeded = succeeded
        self.onInvite = onInvite
        self.onClosed = onClosed
    }

    /// Whether a camera is held right now.
    var isRunning: Bool { capture != nil }

    /// Whether the controller is still listening for the app going to the background, for the test
    /// that stopping lets that go too.
    var isObservingBackground: Bool { backgroundObserver != nil }

    /// Starts the camera and answers the layer to show.
    func start() -> CALayer? {
        guard !hasRead, let capture else { return nil }
        // A capture session is interrupted in the background anyway; this lets it go instead of
        // leaving it waiting to resume.
        backgroundObserver = notificationCenter.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(.none) }
        }
        capture.start(delivering: { [weak self] payload in self?.read(payload) },
                      ended: { [weak self] _ in self?.close(.unavailableNow) })
        return capture.previewLayer
    }

    private func close(_ line: DuoCodeEntryModel.CameraLine) {
        guard isRunning else { return }
        stop()
        onClosed(line)
    }

    /// One payload the camera read. The first that is a duo link is the one used; the payload
    /// itself is dropped here and goes nowhere.
    func read(_ payload: String) {
        guard !hasRead, isRunning, let invite = DuoCodeEntryModel.scan(payload) else { return }
        hasRead = true
        stop()
        if onInvite(invite) { succeeded() }
    }

    /// Stops the camera and lets it go; it is never started again by this controller.
    func stop() {
        if let backgroundObserver { notificationCenter.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        capture?.stop()
        capture = nil
    }
}

// MARK: - The view

/// The camera's preview, filling the space the code-entry sheet gives it while it scans. It is
/// made when the sheet switches to scanning and taken apart when it switches back, closes, or
/// reads a code, and taking it apart stops the camera.
struct DuoQRScannerView: UIViewRepresentable {
    var onInvite: (DuoParsedInvite) -> Bool
    var onClosed: (DuoCodeEntryModel.CameraLine) -> Void
    var makeCapture: @MainActor () -> DuoQRCapturing = { DuoLiveQRCapture() }

    func makeCoordinator() -> DuoQRScanController {
        DuoQRScanController(capture: makeCapture(), onInvite: onInvite, onClosed: Self.deferred(onClosed))
    }

    func makeUIView(context: Context) -> DuoQRPreviewView {
        let view = DuoQRPreviewView()
        view.backgroundColor = .black
        view.previewLayer = context.coordinator.start()
        return view
    }

    func updateUIView(_ view: DuoQRPreviewView, context: Context) {
        context.coordinator.onInvite = onInvite
        context.coordinator.onClosed = Self.deferred(onClosed)
    }

    static func dismantleUIView(_ view: DuoQRPreviewView, coordinator: DuoQRScanController) {
        coordinator.stop()
        view.previewLayer = nil
    }

    /// A turn later: the sheet's state must not change while SwiftUI is still building or taking
    /// apart a view, which is where a closing camera can be found.
    private static func deferred(_ onClosed: @escaping (DuoCodeEntryModel.CameraLine) -> Void) -> (DuoCodeEntryModel.CameraLine) -> Void {
        { line in DispatchQueue.main.async { onClosed(line) } }
    }
}

/// A plain view that hosts the preview layer and keeps it the size of the view.
final class DuoQRPreviewView: UIView {
    var previewLayer: CALayer? {
        didSet {
            guard previewLayer !== oldValue else { return }
            oldValue?.removeFromSuperlayer()
            if let previewLayer { layer.addSublayer(previewLayer) }
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}
#endif

import AVFoundation
import SwiftUI

/// The iPad's camera: a live preview for the booth screen, and a recording of the guest while
/// the rig runs. That recording is the "App Recorded Video" clip the video template is built on.
///
/// Records at the highest frame rate the camera offers up to 120 (a slow-motion ramp needs real
/// frames), at 1080p or the biggest size that rate allows. No audio.
@MainActor
final class Recorder: NSObject, ObservableObject {
    static let shared = Recorder()

    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var status = "Camera not started"
    @Published private(set) var fps: Double = 0

    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private var device: AVCaptureDevice?
    private var rotation: AVCaptureDevice.RotationCoordinator?  // nil for external cameras
    private var finish: ((URL?) -> Void)?

    /// The booth camera setting: "canon" (the Canon over USB-C as an external video camera),
    /// "front" or "back" (this iPad's own cameras).
    var source: String { UserDefaults.standard.string(forKey: "booth.camera") ?? "back" }
    var facing: AVCaptureDevice.Position { source == "front" ? .front : .back }

    /// The Canon shows up over USB-C as an external AVCapture device once it is in movie/streaming
    /// (UVC) mode — this is the AuraBooth path: no CCAPI, no PTP, just a video device.
    static func externalCamera() -> AVCaptureDevice? {
        var types: [AVCaptureDevice.DeviceType] = []
        if #available(iOS 17.0, *) { types.append(.external) }
        guard !types.isEmpty else { return nil }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
            .devices.first
    }

    /// True when a Canon (external USB-C camera) is currently attached.
    static var canonAttached: Bool { externalCamera() != nil }

    /// Every video capture device iPadOS currently sees, for the log — so we can tell whether the
    /// Canon is showing up as an external camera at all.
    static func videoDeviceList() -> String {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(iOS 17.0, *) { types.append(.external) }
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        let list = ds.devices.map { d -> String in
            var kind = "built-in"
            if #available(iOS 17.0, *), d.deviceType == .external { kind = "EXTERNAL" }
            return "\(d.localizedName) [\(kind)]"
        }
        return list.isEmpty ? "none" : list.joined(separator: ", ")
    }

    /// Ask for camera access during setup, not on the booth screen in front of a guest.
    static func prepareAuthorization() async {
        let before = AVCaptureDevice.authorizationStatus(for: .video)
        if before == .notDetermined {
            Log.write("camera: asking for permission")
            let ok = await AVCaptureDevice.requestAccess(for: .video)
            Log.write("camera: permission \(ok ? "allowed" : "DENIED")")
        }
    }

    func start() async {
        guard !isRunning else { return }
        Log.write("camera: starting (permission \(AVCaptureDevice.authorizationStatus(for: .video).rawValue): 0 undetermined, 1 restricted, 2 denied, 3 allowed)")
        let cam: AVCaptureDevice?
        if source == "canon" {
            cam = Self.externalCamera()
            if cam == nil {
                status = "Canon not detected over USB-C — set the camera to movie/streaming (UVC) mode"
                Log.write("camera: canon (external) not found over USB-C")
                return
            }
        } else {
            cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: facing)
                ?? AVCaptureDevice.default(for: .video)
        }
        guard let cam else {
            status = "No camera on this device"
            Log.write("camera: none found")
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            status = "Camera access is off — Settings → Robot Arm → Camera"
            Log.write("camera: access denied")
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .inputPriority       // so the format chosen below is kept
        session.inputs.forEach { session.removeInput($0) }
        do {
            let input = try AVCaptureDeviceInput(device: cam)
            guard session.canAddInput(input) else { session.commitConfiguration(); status = "Could not use the camera"; return }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            status = "Camera error: \(error.localizedDescription)"
            return
        }
        if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        device = cam
        pickFormat(cam)
        // An external (Canon) camera already outputs a level, correctly-oriented image; the
        // horizon-level rotation is only for the iPad's own cameras.
        rotation = source == "canon" ? nil : AVCaptureDevice.RotationCoordinator(device: cam, previewLayer: nil)

        let s = session
        await Task.detached { s.startRunning() }.value
        isRunning = true
        Log.write("camera: \(source) running — \(status)")
    }

    func stop() {
        guard isRunning else { return }
        let s = session
        Task.detached { s.stopRunning() }
        isRunning = false
        status = "Camera stopped"
    }

    /// Re-open with whatever camera is now chosen.
    func restart() async {
        stop()
        await start()
    }

    /// Highest frame rate up to 120, and the largest frame at that rate.
    private func pickFormat(_ cam: AVCaptureDevice) {
        let rates: [Double] = [120, 60, 30]
        for want in rates {
            let candidates = cam.formats.filter { f in
                f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= want - 0.5 }
            }
            guard let best = candidates.max(by: { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
            }) else { continue }
            do {
                try cam.lockForConfiguration()
                cam.activeFormat = best
                let d = CMTime(value: 1, timescale: CMTimeScale(want))
                cam.activeVideoMinFrameDuration = d
                cam.activeVideoMaxFrameDuration = d
                cam.unlockForConfiguration()
                let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
                fps = want
                status = "\(dims.width)×\(dims.height) at \(Int(want)) fps"
                return
            } catch {
                continue
            }
        }
        status = "Using the camera's default format"
    }

    /// Start recording to a new file. Stop with `stopRecording()`.
    func startRecording() {
        guard isRunning, !isRecording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("guest-\(Int(Date().timeIntervalSince1970)).mov")
        try? FileManager.default.removeItem(at: url)
        // Level horizon: the iPad is held landscape either way round, and the clip must not
        // come out upside down when it is the other way round.
        if let conn = output.connection(with: .video), let r = rotation {
            let angle = r.videoRotationAngleForHorizonLevelCapture
            if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
        }
        isRecording = true
        status = "Recording"
        output.startRecording(to: url, recordingDelegate: self)
    }

    /// Stop and return the file, or nil if the camera never finished writing it.
    func stopRecording() async -> URL? {
        guard isRecording else { return nil }
        let url: URL? = await withCheckedContinuation { cont in
            var done = false
            finish = { u in guard !done else { return }; done = true; cont.resume(returning: u) }
            output.stopRecording()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !done else { return }
                done = true
                self.finish = nil
                cont.resume(returning: nil)
            }
        }
        isRecording = false
        status = url == nil ? "Recording failed" : "Recorded"
        return url
    }
}

extension Recorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            let f = self.finish
            self.finish = nil
            // An error with a file that still has frames (the usual "stopped" case) is fine.
            let ok = error == nil || FileManager.default.fileExists(atPath: outputFileURL.path)
            f?(ok ? outputFileURL : nil)
        }
    }
}

/// The live camera picture.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.layer.session = session
        v.layer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        override var layer: AVCaptureVideoPreviewLayer { super.layer as! AVCaptureVideoPreviewLayer }
    }
}

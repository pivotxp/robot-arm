import Foundation
import Photos
import SwiftUI

/// The booth screen's settings, and whether the app is showing it.
///
/// The app opens on the booth screen — one button, nothing else — unless **Support mode** is on.
/// Support mode is for the crew: with it on, the app opens straight to Programs and the booth
/// screen has a plain "Support" button back out, so nobody types the PIN twenty times while
/// setting up. Turn it off before guests arrive and the PIN is required again.
@MainActor
final class Booth: ObservableObject {
    static let shared = Booth()
    private let d = UserDefaults.standard

    /// The booth screen is showing.
    @Published var locked: Bool

    @Published var supportMode: Bool { didSet { d.set(supportMode, forKey: "booth.support") } }

    /// Which program Capture runs. Nil until one is chosen.
    @Published var program: Int? {
        didSet { if let p = program { d.set(p, forKey: "booth.program") } else { d.removeObject(forKey: "booth.program") } }
    }

    /// Seconds of 3-2-1 before the rig moves. 0 = none.
    @Published var countdown: Int { didSet { d.set(countdown, forKey: "booth.countdown") } }

    /// "canon", "back" or "front". The Canon records on the camera and the file is pulled over;
    /// the other two are this iPad's cameras.
    @Published var camera: String { didSet { d.set(camera, forKey: "booth.camera") } }
    var usesCanon: Bool { camera == "canon" }

    /// Record this long after the rig reports done, so the last frames are never cut.
    @Published var tail: Double { didSet { d.set(tail, forKey: "booth.tail") } }

    /// Seconds to fire the rig BEFORE the countdown ends. Default = the whole countdown, so the
    /// rail is triggered as 3-2-1 begins and spins up during the count.
    @Published var lead: Double { didSet { d.set(lead, forKey: "booth.lead") } }

    /// Pre-roll (CanonPivotBot's model): seconds the rig is fired relative to GO (the end of the
    /// countdown, when recording starts). NEGATIVE gives the rig a head start DURING the countdown
    /// so it is already moving at GO — this is how the rail/arm spin-up is hidden. 0 fires at GO.
    @Published var preRoll: Double { didSet { d.set(preRoll, forKey: "booth.preRoll") } }

    /// The crew PIN Kyle asked for. Changeable on the iPad under Booth; this is the value until
    /// one is set there.
    static let defaultPIN = "0485"

    /// Four or more digits.
    var pin: String {
        let p = d.string(forKey: "booth.pin") ?? ""
        return p.count >= 4 ? p : Self.defaultPIN
    }
    var pinIsDefault: Bool { (d.string(forKey: "booth.pin") ?? "").count < 4 }

    func setPIN(_ new: String) {
        let digits = new.filter(\.isNumber)
        guard digits.count >= 4 else { return }
        d.set(digits, forKey: "booth.pin")
    }

    private init() {
        supportMode = d.bool(forKey: "booth.support")
        // 14 is the move the booth is being built around. A capture that says "no program
        // chosen" on a fresh install is a dead button for no reason.
        program = d.object(forKey: "booth.program") as? Int ?? 14
        countdown = d.object(forKey: "booth.countdown") as? Int ?? 5
        camera = d.string(forKey: "booth.camera") ?? "back"
        tail = d.object(forKey: "booth.tail") as? Double ?? 1.0
        // Default: fire the rig when the countdown STARTS, so the rail's HTTPS spin-up and the
        // wire cue overlap the 3-2-1 instead of following it. The slider can pull it back toward 0.
        lead = d.object(forKey: "booth.lead") as? Double ?? Double(d.object(forKey: "booth.countdown") as? Int ?? 3)
        preRoll = d.object(forKey: "booth.preRoll") as? Double ?? -3.0
        // Guests first, crew only when asked.
        locked = !d.bool(forKey: "booth.support")
    }

    func tryUnlock(_ entered: String) -> Bool {
        guard entered == pin else { return false }
        locked = false
        return true
    }
}

/// One capture, start to finish: count down, record the guest, run the rig, build the clip,
/// save it to Photos. Reports each phase for the booth screen.
@MainActor
final class CaptureFlow: ObservableObject {
    static let shared = CaptureFlow()

    enum Phase: Equatable {
        case idle
        case countdown(Int)
        /// The rig has been fired; the camera starts when the arm goes.
        case armed
        case recording
        case rendering
        case done(URL)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .idle, .done, .failed: return false
            default: return true
            }
        }
    }

    @Published private(set) var phase: Phase = .idle {
        didSet {
            switch phase {
            case .done(let u): Log.write("capture: done — \(u.lastPathComponent)")
            case .failed(let why): Log.write("capture: FAILED — \(why)")
            case .rendering: Log.write("capture: rendering")
            case .recording: Log.write("capture: recording")
            default: break
            }
        }
    }
    /// Something that went wrong without stopping the capture — shown small on the done screen.
    @Published private(set) var note: String?

    private let booth = Booth.shared
    private let runner = Runner.shared
    private let recorder = Recorder.shared
    private let canon = Canon.shared
    private let store = ProgramStore.shared
    private let arm = ArmLink.shared
    private let rail = RailLink.shared
    private var task: Task<Void, Never>?

    /// Plain-language reason Capture will not run right now, or nil.
    var blocker: String? {
        guard let n = booth.program else { return "No program chosen — Programs → Booth" }
        guard let p = store.program(n) else { return "Program \(n) no longer exists — Programs → Booth" }
        let selfRunning = p.railProgram != nil        // the rig runs its own arm; the app doesn't
        if !selfRunning, !arm.connected { return "Arm is not connected" }
        if booth.usesCanon {
            if !canon.isReady { return "Canon is not connected — \(canon.label)" }
        } else if !recorder.isRunning {
            return "Camera: \(recorder.status)"
        }
        if p.railProgram != nil {
            if !rail.connected { return "Rail is not connected" }
            if rail.homed != "1" { return "Rail is not referenced — Programs → Home the rail" }
            if rail.statusError != "0" { return "Rail has a fault — Programs → Clear the fault" }
        }
        if runner.running { return "The rig is still running" }
        return nil
    }

    func capture() {
        guard !phase.isBusy, blocker == nil, let n = booth.program, let program = store.program(n) else { return }
        note = nil
        task = Task { @MainActor in await run(program) }
    }

    func reset() {
        phase = .idle
        note = nil
    }

    /// STOP from the booth screen: the rig, the recording, and this flow.
    func stop() {
        task?.cancel()
        task = nil
        runner.stop()
        Task { @MainActor in
            _ = await recorder.stopRecording()
            if canon.recording { _ = try? await canon.stopMovie() }
        }
        phase = .failed("Stopped")
    }

    private func run(_ program: Program) async {
        Log.write("capture: “\(program.name)” (code \(program.number)) — camera \(booth.camera)")

        let onCanon = booth.usesCanon && canon.isReady
        let filming = onCanon || recorder.isRunning
        if !filming { note = "No camera — the rig ran but nothing was recorded." }
        let selfRunning = program.railProgram != nil

        // 🔑 **CanonPivotBot's model — the rig runs ITSELF.** For a rail program the app sends ONE
        // packet ("1"+program to port 2000) and the PLC + the xArm's onboard program do the whole
        // move, in sync, in hardware — smooth, identical every run. The app must NOT drive or even
        // hold the arm (that blocks the onboard program and makes it stutter), so it releases the
        // arm link first. Two clocks from START: the rig fires `preRoll` before GO (a head start so
        // it is already moving at GO), and recording starts exactly at GO.
        if selfRunning { arm.disconnect() }

        let total = Double(booth.countdown)
        let fireAt = max(0, total + booth.preRoll)     // seconds from START to fire the rig

        // Fire the rig on its own clock.
        let fireTask = Task { @MainActor () -> Bool in
            try? await Task.sleep(nanoseconds: UInt64(fireAt * 1_000_000_000))
            if Task.isCancelled { return false }
            if selfRunning {
                return await rail.sendRawProgram(program.railProgram!)
            } else {
                _ = await runner.prewarm()
                runner.boothLaunchArm(program)         // no rail code: app-driven arm movement
                return true
            }
        }

        // The countdown ticks to GO.
        if booth.countdown > 0 {
            for n in stride(from: booth.countdown, through: 1, by: -1) {
                phase = .countdown(n)
                Haptics.light()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { fireTask.cancel(); return }
            }
        }
        _ = await fireTask.value

        // GO — recording starts NOW, the instant the count ends, exactly as the template expects.
        Haptics.heavy()
        phase = .armed
        if onCanon {
            do { try await canon.startMovie() } catch {
                Log.write("capture: Canon would not record — \(error.localizedDescription)")
                note = "Canon would not record: \(error.localizedDescription)"
            }
        } else if filming {
            recorder.startRecording()
        }
        let recordingStarted = Date()
        phase = .recording

        let need = BoothTemplate.recordingSecondsNeeded + max(0, booth.tail)
        while Date().timeIntervalSince(recordingStarted) < need, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if Task.isCancelled { return }

        guard filming else { phase = .failed("The rig ran, but there is no camera to record with."); return }
        let raw: URL
        if onCanon {
            do { raw = try await canon.stopMovie() } catch {
                phase = .failed("Could not get the movie from the Canon: \(error.localizedDescription)"); return
            }
        } else {
            guard let u = await recorder.stopRecording() else {
                phase = .failed("The camera did not save the recording."); return
            }
            raw = u
        }
        Log.write("capture: recorded \(raw.lastPathComponent)")

        // Free the booth NOW; render in the background. Reconnect the arm link for the next run's
        // telemetry (it does not drive the arm; it just lets the status lights read).
        phase = .idle
        note = nil
        if selfRunning { Task { _ = await arm.connect() } }
        Task.detached {
            do {
                let clip = try await TimelineExporter.export(recordingURL: raw)
                try await Self.saveToPhotos(clip)
                await MainActor.run { Log.write("capture: clip saved (background) — \(clip.lastPathComponent)"); Haptics.success() }
            } catch {
                await MainActor.run { Log.write("capture: background render FAILED — \(error.localizedDescription)") }
            }
        }
    }

    private static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "Booth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Photos access is off — Settings → Robot Arm → Photos"])
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}

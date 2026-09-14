import Foundation
import Photos
import SwiftUI
import UIKit

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

    /// True when the booth program runs its OWN arm move in hardware: it has a rail program and the
    /// arm is cued by the rail's six wires. For these, the app must stay off the arm (so the robot's
    /// onboard program can run) and only trigger the rail — the back end drives the arm, not the app.
    var programIsSelfRunning: Bool {
        guard let n = program, let p = ProgramStore.shared.program(n) else { return false }
        return p.armStart == .signal && p.railProgram != nil
    }

    /// Record this long after the rig reports done, so the last frames are never cut.
    @Published var tail: Double { didSet { d.set(tail, forKey: "booth.tail") } }

    /// Seconds to fire the rig BEFORE the countdown ends. Default = the whole countdown, so the
    /// rail is triggered as 3-2-1 begins and spins up during the count.
    @Published var lead: Double { didSet { d.set(lead, forKey: "booth.lead") } }

    /// Pre-roll (CanonPivotBot's model): seconds the rig is fired relative to GO (the end of the
    /// countdown, when recording starts). NEGATIVE gives the rig a head start DURING the countdown
    /// so it is already moving at GO — this is how the rail/arm spin-up is hidden. 0 fires at GO.
    @Published var preRoll: Double { didSet { d.set(preRoll, forKey: "booth.preRoll") } }

    /// Fine sync between the two machines: seconds the ARM starts AFTER the rail carriage begins to
    /// move. 0 = together (the arm is launched at the rail's RunProgram pulse). A small positive
    /// value holds the snappy arm back to match the heavier carriage's ramp. Dialed in on the booth.
    @Published var armSync: Double { didSet { d.set(armSync, forKey: "booth.armSync") } }

    /// How much to slow the arm so its sweep lasts as long as the rail's travel — 1.0 = the program
    /// as authored (finished in ~9 s, well before the rail), ~0.45 stretches it to ~20 s so the arm
    /// and rail move together the whole shot. Booth only; the authored program is left untouched.
    @Published var armSpeedScale: Double { didSet { d.set(armSpeedScale, forKey: "booth.armSpeedScale") } }

    /// Seconds to record a self-running program's move (the arm+rail run their onboard programs; the
    /// app can't watch the arm, so it records a fixed length rather than polling the flaky rail web
    /// server, which wedges the trigger). Set this to cover the whole preset-14 move.
    @Published var moveLength: Double { didSet { d.set(moveLength, forKey: "booth.moveLength") } }

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
        // The fast-pulse model only needs a ~1 s lead (the rail is pre-armed during the countdown,
        // so all that's left at GO is one quick trigger). The old value was -3 s to cover the slow
        // HTTPS start that no longer happens — reset it once so upgraders get the right timing
        // without touching the slider (that -3 is what made the rig fire before the count reached 1).
        if !d.bool(forKey: "booth.pulseV2") {
            d.set(-1.0, forKey: "booth.preRoll")
            d.set(true, forKey: "booth.pulseV2")
        }
        // Slowing the arm made it worse (Kyle) — put the arm back to full speed and fire at count "1"
        // (build 141, which he called the closest). One-time reset that overrides the earlier tries.
        if !d.bool(forKey: "booth.revert142") {
            d.set(-1.0, forKey: "booth.preRoll")
            d.set(1.0, forKey: "booth.armSpeedScale")
            d.set(true, forKey: "booth.revert142")
        }
        preRoll = d.object(forKey: "booth.preRoll") as? Double ?? -1.0
        armSync = d.object(forKey: "booth.armSync") as? Double ?? 0.0
        armSpeedScale = d.object(forKey: "booth.armSpeedScale") as? Double ?? 1.0
        moveLength = d.object(forKey: "booth.moveLength") as? Double ?? 20.0
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

    /// "GO" has fired for the current capture (arm launched + camera rolling), set the instant the
    /// rail carriage starts. Stops the countdown from clobbering the recording view.
    private var fired = false
    /// When recording actually started rolling — the clock the recording length is measured from.
    private var recStart: Date?

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
        // A self-running program runs the arm from the robot's own onboard program (cued by the rail
        // wires). The app deliberately does NOT connect to the arm for these, so don't require it.
        let selfRunning = p.armStart == .signal && p.railProgram != nil
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

        // Keep the app alive through a brief backgrounding — screen dim, a notification, the
        // operator stepping away to film — so the countdown and the fire don't suspend mid-shot
        // and then resume seconds late (the "freezes on 1, then a 3-5 s delay" report). iOS gives
        // ~30 s, far more than one capture needs.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "booth-capture")
        defer { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) } }

        // Give the rail's flaky web server no other traffic to trip over while we fire — a routine
        // refresh overlapping the pulse is what turned a 0.2 s trigger into a 4.8 s one.
        rail.pauseAuto = true
        defer { rail.pauseAuto = false }

        let onCanon = booth.usesCanon && canon.isReady
        let filming = onCanon || recorder.isRunning
        if !filming { note = "No camera — the rig ran but nothing was recorded." }

        // 🔑 SELF-RUNNING: the arm runs its OWN onboard program in hardware, cued by the rail's six
        // wires. The app only triggers the rail — the RunProgram pulse drops and re-raises the wires,
        // and the robot's program 14 runs itself, in sync, exactly like the original. The app never
        // touches the arm (a control connection would block the onboard program). `driveArm` is
        // false for these; true only for old app-driven programs.
        let selfRunning = program.armStart == .signal && program.railProgram != nil
        let driveArm = !selfRunning

        fired = false
        recStart = nil
        // Prewarm / arm only for OLD app-driven programs. A self-running program is fired the
        // original way (raw packet) and the app never touches the arm or the rail over HTTPS during
        // the shot — the background auto-loop keeps the rail energised.
        let prewarm = Task { @MainActor in driveArm ? await runner.prewarm() : nil }
        let railReady = Task { @MainActor in
            if driveArm, let n = program.railProgram { return await rail.armProgram(n) }
            return true
        }
        let total = Double(booth.countdown)
        let fireAt = max(0, total + booth.preRoll)

        let fireTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(fireAt * 1_000_000_000))
            if Task.isCancelled { return }

            if selfRunning, let n = program.railProgram {
                // 🔑 THE ORIGINAL MECHANISM (CanonPivotBot): one RAW packet to the PLC on port 2000.
                // The PLC runs program 14 — the rail moves AND it raises the six wires, and the
                // robot's onboard program 14 runs the arm off that cue. The HTTPS RunProgram pulse
                // moved the rail but did NOT cue the arm (build 147: "only sliding forward"); the raw
                // trigger is what the arm is wired to respond to. Camera rolls on the same beat.
                self.goNow(program, onCanon: onCanon, filming: filming, driveArm: false)
                _ = await rail.sendRawProgram(n)
                return
            }

            _ = await prewarm.value
            _ = await railReady.value                 // make sure the rail is loaded before we pulse
            let sync = max(0, booth.armSync)
            if let n = program.railProgram {
                _ = await rail.firePulse(n) { [weak self] in
                    guard let self else { return }
                    if sync <= 0 {
                        self.goNow(program, onCanon: onCanon, filming: filming, driveArm: driveArm)
                    } else {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: UInt64(sync * 1_000_000_000))
                            if !Task.isCancelled { self.goNow(program, onCanon: onCanon, filming: filming, driveArm: driveArm) }
                        }
                    }
                }
            } else {
                self.goNow(program, onCanon: onCanon, filming: filming, driveArm: driveArm)
            }
        }

        // Visual countdown. Stops the instant the rig fires so a fast rail doesn't fight it.
        if booth.countdown > 0 {
            for n in stride(from: booth.countdown, through: 1, by: -1) {
                if fired { break }
                phase = .countdown(n)
                Haptics.light()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { fireTask.cancel(); runner.stop(); return }
            }
        }

        // GO. If the rig has not fired yet (rail HTTPS still spinning up on a slow run), hold on
        // "Get ready…" — never a frozen number — until it moves. Up to 15 s, then give up cleanly.
        if !fired { phase = .armed }
        let waitStart = Date()
        while recStart == nil, Date().timeIntervalSince(waitStart) < 15, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if Task.isCancelled { return }
        guard let began = recStart else {
            fireTask.cancel()
            phase = .failed(filming ? "The rig did not start — check the rail." : "The rig ran, but there is no camera to record with.")
            return
        }

        if selfRunning {
            // Record the WHOLE preset-14 move for a fixed length — NO position polling. Polling the
            // rail's flaky web server WHILE the trigger pulse was still going out wedged the server
            // and delayed the rail 11 s (build 146). A fixed length keeps the link silent so the
            // pulse fires instantly and the whole coordinated move is captured. Tune "Move length".
            let moveLen = max(2, booth.moveLength) + max(0, booth.tail)
            while Date().timeIntervalSince(began) < moveLen, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            Log.write("capture: preset-14 move recorded (\(Fmt.num(booth.moveLength)) s)")
        } else {
            let need = BoothTemplate.recordingSecondsNeeded + max(0, booth.tail)
            while Date().timeIntervalSince(began) < need, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
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

        phase = .idle
        note = nil
        // Re-arm the rail right away so the NEXT guest's capture fires just as fast (only the pulse
        // left). The program just ran, so it is almost certainly still loaded — this mostly confirms.
        if let n = program.railProgram { Task { _ = await rail.armProgram(n) } }
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

    /// The single "GO" beat: launch the arm and start the camera together, the instant the rail
    /// carriage begins to move. Idempotent — the first call wins — so the countdown and the fire
    /// timer can both reach for it without double-firing.
    @MainActor
    private func goNow(_ program: Program, onCanon: Bool, filming: Bool, driveArm: Bool) {
        guard !fired else { return }
        fired = true
        Haptics.heavy()
        // Self-running programs: the arm is ALREADY going (the rail's wires cued its onboard program).
        // Only drive the arm for old app-driven programs.
        if driveArm { runner.boothLaunchArm(program) }
        phase = .recording
        Log.write(driveArm ? "capture: GO — arm + camera together"
                           : "capture: GO — rail triggered, arm running itself + camera")
        if onCanon {
            Task { @MainActor in
                do { try await canon.startMovie(); recStart = Date() }
                catch {
                    Log.write("capture: Canon would not record — \(error.localizedDescription)")
                    note = "Canon would not record: \(error.localizedDescription)"
                    recStart = Date()       // mark anyway so the flow finishes and stops cleanly
                }
            }
        } else if filming {
            recorder.startRecording()
            recStart = Date()
        } else {
            recStart = Date()               // no camera; the rig still ran
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

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

    /// Record this long after the rig reports done, so the last frames are never cut.
    @Published var tail: Double { didSet { d.set(tail, forKey: "booth.tail") } }

    /// Four or more digits. Stored on the iPad, never in the code.
    var pin: String {
        let p = d.string(forKey: "booth.pin") ?? ""
        return p.count >= 4 ? p : "0000"
    }
    var pinIsDefault: Bool { (d.string(forKey: "booth.pin") ?? "").count < 4 }

    func setPIN(_ new: String) {
        let digits = new.filter(\.isNumber)
        guard digits.count >= 4 else { return }
        d.set(digits, forKey: "booth.pin")
    }

    private init() {
        supportMode = d.bool(forKey: "booth.support")
        program = d.object(forKey: "booth.program") as? Int
        countdown = d.object(forKey: "booth.countdown") as? Int ?? 3
        tail = d.object(forKey: "booth.tail") as? Double ?? 1.0
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

    @Published private(set) var phase: Phase = .idle
    /// Something that went wrong without stopping the capture — shown small on the done screen.
    @Published private(set) var note: String?

    private let booth = Booth.shared
    private let runner = Runner.shared
    private let recorder = Recorder.shared
    private let store = ProgramStore.shared
    private let arm = ArmLink.shared
    private let rail = RailLink.shared
    private var task: Task<Void, Never>?

    /// Plain-language reason Capture will not run right now, or nil.
    var blocker: String? {
        guard let n = booth.program else { return "No program chosen — Programs → Booth" }
        guard let p = store.program(n) else { return "Program \(n) no longer exists — Programs → Booth" }
        if !arm.connected { return "Arm is not connected" }
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
        Task { @MainActor in _ = await recorder.stopRecording() }
        phase = .failed("Stopped")
    }

    private func run(_ program: Program) async {
        Log.write("capture: “\(program.name)” (code \(program.number))")
        if booth.countdown > 0 {
            for n in stride(from: booth.countdown, through: 1, by: -1) {
                phase = .countdown(n)
                Haptics.light()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
        }

        // Camera first, then the rig — so the first frames of the move are on film.
        let filming = recorder.isRunning
        if filming { recorder.startRecording() } else { note = "No camera — the rig ran but nothing was recorded." }
        phase = .recording
        try? await Task.sleep(nanoseconds: 300_000_000)

        runner.run(program)
        // The runner reports through `running`; wait for it, but never forever.
        let started = Date()
        while runner.running, Date().timeIntervalSince(started) < 90, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if Task.isCancelled { return }
        let rigResult = runner.status
        if !rigResult.hasPrefix("Done") {
            note = rigResult
            Log.write("capture: rig reported “\(rigResult)”")
        }

        try? await Task.sleep(nanoseconds: UInt64(max(0, booth.tail) * 1_000_000_000))
        guard filming else {
            phase = rigResult.hasPrefix("Done") ? .failed("The rig ran, but there is no camera to record with.") : .failed(rigResult)
            return
        }
        guard let raw = await recorder.stopRecording() else {
            phase = .failed("The camera did not save the recording.")
            return
        }
        Log.write("capture: recorded \(raw.lastPathComponent)")

        phase = .rendering
        do {
            let clip = try await TimelineExporter.export(recordingURL: raw)
            try await Self.saveToPhotos(clip)
            Log.write("capture: clip saved to Photos — \(clip.lastPathComponent)")
            Haptics.success()
            phase = .done(clip)
        } catch {
            Log.write("capture: render FAILED — \(error.localizedDescription)")
            phase = .failed("Could not build the clip: \(error.localizedDescription)")
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

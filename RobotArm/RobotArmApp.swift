import SwiftUI

@main
struct RobotArmApp: App {
    @StateObject private var arm = ArmLink.shared
    @StateObject private var rail = RailLink.shared
    @StateObject private var runner = Runner.shared
    @StateObject private var store = ProgramStore.shared
    @StateObject private var booth = Booth.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if booth.locked {
                    // The booth screen: one button. The way out is the PIN, or Support mode.
                    BoothView()
                } else {
                    VStack(spacing: 0) {
                        StatusStrip()
                        Divider()
                        NavigationStack {
                            ProgramsView()
                        }
                    }
                }
            }
            .task {
                store.load()
                BoothTemplate.applyIfFresh()
                arm.startAutoConnect()
                rail.startAutoConnect()
                Canon.shared.start()
                Log.write("launch — build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
                await runLaunchRequest()
            }
        }
    }
}

/// Always on screen: is the arm connected, is the rail connected, what is happening, and STOP.
struct StatusStrip: View {
    @ObservedObject private var arm = ArmLink.shared
    @ObservedObject private var rail = RailLink.shared
    @ObservedObject private var runner = Runner.shared
    @ObservedObject private var canon = Canon.shared

    var body: some View {
        HStack(spacing: 24) {
            light(on: arm.connected, label: "Arm", detail: armDetail)
            light(on: rail.connected, label: "Rail", detail: railDetail)
            light(on: canon.isReady, label: "Canon", detail: canon.label)
            Spacer()
            Text(runner.status)
                .font(.title3)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(runner.status.hasPrefix("STOPPED") || runner.status.contains("fault") ? .red : .primary)
            Button {
                runner.stop()
            } label: {
                Text("STOP")
                    .font(.system(size: 28, weight: .black))
                    .frame(width: 140, height: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
    }

    private var armDetail: String {
        guard arm.connected else { return "waiting…" }
        if arm.errorCode != 0 { return "fault \(arm.errorCode)" }
        switch arm.armState {
        case 1: return "moving"
        case 2: return "ready"
        case 3: return "paused"
        case 4: return "stopped"
        default: return "connected"
        }
    }

    private var railDetail: String {
        guard rail.connected else { return rail.lastError.isEmpty ? "waiting…" : rail.lastError }
        if let f = rail.foreignMotion { return f }
        return "at \(rail.currentPosition) mm" + (rail.homed == "1" ? "" : " · not homed")
    }

    private func light(on: Bool, label: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(on ? Color.green : Color.red)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(minWidth: 140, alignment: .leading)
    }
}


// MARK: - Doing one thing from the Mac
//
// The iPad sits on the rig; the Mac is where the log is read. These launch arguments let a test
// be started over the cable without touching the screen:
//
//   xcrun devicectl device process launch --device <id> com.pivotxp.armcontrol -- -measure 14
//   xcrun devicectl device process launch --device <id> com.pivotxp.armcontrol -- -run 14
//   xcrun devicectl device process launch --device <id> com.pivotxp.armcontrol -- -capture YES -program 14
//
// `-measure N` fires rail program N with the arm standing still and writes to robotarm.log whether
// the control box raised N on the six wires, and how long after the trigger. `-run N` runs program
// N exactly as the Run button would. Both wait up to two minutes for the links to come up first.
extension RobotArmApp {
    private func runLaunchRequest() async {
        let d = UserDefaults.standard
        let measure = d.object(forKey: "measure") != nil ? d.integer(forKey: "measure") : nil
        let run = d.object(forKey: "run") != nil ? d.integer(forKey: "run") : nil
        let capture = d.bool(forKey: "capture")
        guard measure != nil || run != nil || capture else { return }

        Log.write("launch request: \(measure.map { "measure \($0)" } ?? "") \(run.map { "run \($0)" } ?? "")\(capture ? "capture" : "")")
        // Two minutes: long enough to plug the Ethernet in after launching from the Mac.
        for _ in 0..<240 where !(arm.connected && rail.connected) {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard arm.connected, rail.connected else {
            Log.write("launch request: gave up — arm \(arm.connected ? "up" : "DOWN"), rail \(rail.connected ? "up" : "DOWN")")
            return
        }
        if capture {
            // The whole booth flow, exactly as the CAPTURE button does it. Needs the booth
            // screen up (it owns the camera) and a program chosen under Booth — or given here
            // with `-program N`, which also sets it for the button.
            if let p = d.string(forKey: "program"), let n = Int(p) { booth.program = n }
            booth.locked = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let why = CaptureFlow.shared.blocker { Log.write("launch request: capture refused — \(why)") }
            else { CaptureFlow.shared.capture() }
        } else if let n = measure {
            runner.measureSignal(railProgram: n)
        } else if let n = run, let p = store.program(n) {
            runner.run(p)
        } else if let n = run {
            Log.write("launch request: no program at code \(n)")
        }
    }
}

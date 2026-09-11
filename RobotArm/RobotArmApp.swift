import SwiftUI

@main
struct RobotArmApp: App {
    @StateObject private var arm = ArmLink.shared
    @StateObject private var rail = RailLink.shared
    @StateObject private var runner = Runner.shared
    @StateObject private var store = ProgramStore.shared

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                StatusStrip()
                Divider()
                NavigationStack {
                    ProgramsView()
                }
            }
            .task {
                store.load()
                arm.startAutoConnect()
                rail.startAutoConnect()
            }
        }
    }
}

/// Always on screen: is the arm connected, is the rail connected, what is happening, and STOP.
struct StatusStrip: View {
    @ObservedObject private var arm = ArmLink.shared
    @ObservedObject private var rail = RailLink.shared
    @ObservedObject private var runner = Runner.shared

    var body: some View {
        HStack(spacing: 24) {
            light(on: arm.connected, label: "Arm", detail: armDetail)
            light(on: rail.connected, label: "Rail", detail: railDetail)
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

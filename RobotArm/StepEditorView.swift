import SwiftUI

/// Screen 3: one step. The easy way to set a joint move is to drive the real arm with the big
/// buttons while watching it (and the picture), then press "Save this position." Typing exact
/// numbers is still there, tucked under "Type exact numbers."
struct StepEditorView: View {
    @Binding var step: Step
    /// The factory version of this step (same position in the factory program), if there is one.
    var factory: Step? = nil
    @ObservedObject private var arm = ArmLink.shared
    @ObservedObject private var runner = Runner.shared
    @State private var stepSize: Double = 5
    @State private var busy = false
    @State private var showNumbers = false

    private let jointNames = ["Pan", "Lift", "Bend", "Tilt", "Roll"]
    private let jointHelp = [
        "turns the whole arm left / right",
        "shoulder, raises / lowers the arm",
        "elbow",
        "wrist up / down",
        "wrist twist",
    ]
    private let poseNames = ["X (mm)", "Y (mm)", "Z (mm)", "Roll (°)", "Pitch (°)", "Yaw (°)"]

    var body: some View {
        Form {
            Section {
                Picker("What this step does", selection: $step.kind) {
                    ForEach(StepKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            // Live picture of the arm.
            if step.kind != .pause {
                Section {
                    ArmView(joints: pictureJoints)
                        .frame(height: 200)
                        .listRowInsets(EdgeInsets())
                }
            }

            if step.kind == .joint {
                driveSection
            }

            if step.kind == .line {
                Section("Where the camera goes") {
                    ForEach(0..<6, id: \.self) { i in
                        numberRow(poseNames[i], value: $step.pose[i], nudge: i < 3 ? 10 : 1)
                    }
                }
                captureLineButtons
            }

            if step.kind != .pause {
                DisclosureGroup(isExpanded: $showNumbers) {
                    numberRow(step.kind == .line ? "Speed (mm per second)" : "Speed (degrees per second)",
                              value: $step.speed, nudge: 5)
                    numberRow("Acceleration", value: $step.acc, nudge: 50)
                    numberRow("Blend radius (mm) — 0 stops here, bigger rounds the corner",
                              value: $step.radius, nudge: 10)
                    if step.kind == .joint {
                        ForEach(0..<5, id: \.self) { i in
                            numberRow(jointNames[i] + " (°)", value: $step.joints[i], nudge: 1)
                        }
                    }
                } label: {
                    Label("Type exact numbers", systemImage: "keyboard")
                }
            }

            Section(step.kind == .pause ? "How long to wait" : "After this step") {
                numberRow("Wait this many seconds before the next step", value: $step.pauseAfter, nudge: 0.5)
            }

            if !step.warnings.isEmpty {
                Section {
                    ForEach(step.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
            }

            if let f = factory, !step.sameSettings(as: f) {
                Section {
                    Button(role: .destructive) {
                        step = f
                    } label: {
                        Label("Put this step back to factory", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("Factory setting: \(f.summary)")
                        .font(.caption.monospacedDigit())
                }
            }
        }
        .navigationTitle(step.kind.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { arm.startLivePolling() }
        .onDisappear { arm.stopLivePolling() }
    }

    // MARK: Drive the arm (joint steps)

    @ViewBuilder private var driveSection: some View {
        if !arm.connected {
            Section("Drive the arm") {
                Text("Connect the arm to drive it. You can still type numbers below.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else if !arm.enabled {
            Section("Drive the arm") {
                Button {
                    busy = true
                    Task { _ = await arm.ensureEnabled(); busy = false }
                } label: {
                    Label(busy ? "Turning on…" : "Turn the arm on to drive it", systemImage: "power")
                }
                .disabled(busy || runner.running)
            }
        } else {
            Section {
                Picker("Each tap moves", selection: $stepSize) {
                    Text("1°").tag(1.0); Text("5°").tag(5.0); Text("15°").tag(15.0)
                }
                .pickerStyle(.segmented)
                ForEach(0..<5, id: \.self) { i in jogRow(i) }
            } header: {
                Text("Drive the arm")
            } footer: {
                Text("Move the arm with the buttons while you watch it, then Save.")
            }
            Section {
                Button {
                    var j = arm.joints
                    while j.count < 5 { j.append(0) }
                    step.joints = j.prefix(5).map { ($0 * 10).rounded() / 10 }
                } label: {
                    Label("Save this position into the step", systemImage: "square.and.arrow.down")
                        .font(.headline)
                }
                .disabled(arm.joints.count < 5 || busy || runner.running)

                Button {
                    busy = true
                    Task { runner.test(step); busy = false }
                } label: {
                    Label("Move the arm to the saved position", systemImage: "play.circle")
                }
                .disabled(busy || runner.running)
            } footer: {
                Text("Saved: " + step.joints.map(Fmt.num).joined(separator: ", "))
                    .font(.caption.monospacedDigit())
            }
        }
    }

    private func jogRow(_ i: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(jointNames[i]).font(.headline)
                Text(jointHelp[i]).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { jog(i, -stepSize) } label: {
                Image(systemName: "minus.circle.fill").font(.system(size: 34))
            }.buttonStyle(.borderless)
            Text(liveAngle(i))
                .font(.title3.monospacedDigit()).frame(width: 66)
            Button { jog(i, stepSize) } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 34))
            }.buttonStyle(.borderless)
        }
        .disabled(busy || runner.running)
    }

    private func jog(_ i: Int, _ delta: Double) {
        guard !busy else { return }
        busy = true
        Task { await arm.jogJoint(i, delta); busy = false }
    }

    private func liveAngle(_ i: Int) -> String {
        guard arm.joints.count == 5 else { return "—" }
        return Fmt.num((arm.joints[i] * 10).rounded() / 10)
    }

    /// What the picture shows: the live arm when connected, otherwise the saved pose.
    private var pictureJoints: [Double] {
        if arm.connected, arm.joints.count == 5 { return arm.joints }
        if step.kind == .joint { return step.joints }
        return [0, 0, 0, 0, 0]
    }

    // MARK: Line capture buttons

    @ViewBuilder private var captureLineButtons: some View {
        Section {
            Button {
                busy = true
                Task { runner.test(step); busy = false }
            } label: {
                Label("Move the arm here now", systemImage: "play.circle.fill")
            }
            .disabled(!arm.connected || busy || runner.running)
            Button {
                Task { if let p = await arm.readTcpPose() { step.pose = p.map { ($0 * 10).rounded() / 10 } } }
            } label: {
                Label("Use where the arm is right now", systemImage: "arrow.down.to.line")
            }
            .disabled(!arm.connected || busy || runner.running)
        }
    }

    // MARK: Typed number row

    private func numberRow(_ label: String, value: Binding<Double>, nudge: Double) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 16)
            Button { value.wrappedValue = round1(value.wrappedValue - nudge) } label: {
                Image(systemName: "minus.circle.fill").font(.title)
            }.buttonStyle(.borderless)
            TextField("0", value: value, format: .number.grouping(.never))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.center)
                .font(.title3.monospacedDigit())
                .frame(width: 90)
                .textFieldStyle(.roundedBorder)
            Button { value.wrappedValue = round1(value.wrappedValue + nudge) } label: {
                Image(systemName: "plus.circle.fill").font(.title)
            }.buttonStyle(.borderless)
        }
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}

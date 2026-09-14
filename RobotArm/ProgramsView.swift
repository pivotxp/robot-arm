import SwiftUI

/// Screen 1: every program, with a Run button. Tap a row to edit it.
///
/// Every code the rail's control box accepts (0–63) is reachable from here: the ones that have
/// a program show it, the rest can be given one with "New program". Codes whose rail slot holds
/// no movement say so, so nobody wonders why the carriage sat still.
struct ProgramsView: View {
    @ObservedObject private var store = ProgramStore.shared
    @ObservedObject private var arm = ArmLink.shared
    @ObservedObject private var rail = RailLink.shared
    @ObservedObject private var runner = Runner.shared
    @ObservedObject private var booth = Booth.shared
    @State private var showTemplate = false
    @State private var showPINChange = false
    @State private var newPIN = ""
    @State private var showNew = false
    @State private var newCode = 39
    @State private var showEmptyCodes = false
    @State private var measureCode = 14
    @State private var showMeasure = false

    private var usedCodes: Set<Int> { Set(store.programs.map(\.number)) }
    private var freeCodes: [Int] { RailCatalog.codes.filter { !usedCodes.contains($0) } }

    var body: some View {
        List {
            Section {
                ForEach(store.programs) { program in
                    NavigationLink(value: program.number) { row(program) }
                }
            } header: {
                Text("Programs · \(store.programs.count) of \(RailCatalog.codes.count) codes")
            } footer: {
                Text("A code is one number the rail's control box understands, 0–63. Rail moves are stored at codes 1–15 and 17–38; every code can carry arm steps.")
            }

            Section {
                Picker("Capture runs", selection: $booth.program) {
                    Text("Nothing chosen").tag(Int?.none)
                    ForEach(store.programs) { p in
                        Text("\(p.number) · \(p.name)").tag(Optional(p.number))
                    }
                }
                Stepper("Countdown: \(booth.countdown == 0 ? "none" : "\(booth.countdown) s")", value: $booth.countdown, in: 0...10)
                Toggle("Support mode — open the app without the PIN", isOn: $booth.supportMode)
                Button {
                    newPIN = ""
                    showPINChange = true
                } label: {
                    Label(booth.pinIsDefault ? "Set the crew PIN (still the default)" : "Change the crew PIN", systemImage: "lock")
                }
                Button {
                    booth.locked = true
                } label: {
                    Label("Go to the booth screen", systemImage: "camera.fill")
                }
            } header: {
                Text("Booth")
            } footer: {
                Text("The booth screen is one CAPTURE button: it counts down, records the guest on this iPad's camera while the program runs, builds the clip with the video template and saves it to Photos. With Support mode off the app opens on that screen and leaving it takes three taps in the top-left corner plus the PIN. With it on, the app opens here and the booth screen has a Support button.")
            }

            Section {
                LabeledContent("Carriage", value: rail.connected ? "\(rail.currentPosition) mm" : "not connected")
                LabeledContent("Referenced", value: rail.connected ? (rail.homed == "1" ? "yes" : "no — home it") : "—")
                if rail.connected, rail.statusError != "0" {
                    LabeledContent("Fault", value: "E\(rail.statusError)")
                    Button {
                        Task { await rail.clearFault() }
                    } label: {
                        Label(rail.busy == "Clearing fault" ? "Clearing…" : "Clear the fault", systemImage: "exclamationmark.triangle")
                    }
                    .disabled(!rail.busy.isEmpty || runner.running)
                }
                Button {
                    Task { await rail.home() }
                } label: {
                    Label(rail.busy == "Homing" ? "Homing… (up to a minute)" : "Home the rail", systemImage: "house")
                }
                .disabled(!rail.connected || !rail.busy.isEmpty || runner.running)
            } header: {
                Text("Rail")
            } footer: {
                Text("Homing is lost every time the rail's control box is powered off, and it refuses to run a program until the rail is referenced again. The rail moves to its reference switch.")
            }

            Section {
                Button {
                    showMeasure = true
                } label: {
                    Label("Test the wires", systemImage: "waveform.path.ecg")
                }
                .disabled(!rail.connected || !arm.connected || runner.running)
                if let l = runner.lastSignal {
                    Text(String(format: "Last seen: program %d signalled %.2f s after the trigger.", l.program, l.latency))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("The wires")
            } footer: {
                Text("Fires a rail program with the arm standing still and reports whether the control box raised that number on the six wires into CI1–CI6, and how long after the trigger. Do this once on a new rig. The rail moves.")
            }

            Section {
                DisclosureGroup(isExpanded: $showEmptyCodes) {
                    ForEach(freeCodes, id: \.self) { code in
                        HStack {
                            Text("\(code)")
                                .font(.title3.monospacedDigit().bold())
                                .frame(width: 44, alignment: .trailing)
                            Text(RailCatalog.hasMove(code) ? "Rail move stored, no arm program" : "Empty on both machines")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Add") { newCode = code; showNew = true }
                                .buttonStyle(.bordered)
                        }
                    }
                } label: {
                    Label("Unused codes · \(freeCodes.count)", systemImage: "number")
                }
            } footer: {
                Text("Nothing is stored at these codes on the arm. Add a program to one and the rail will still only move if its control box has a move at that number.")
            }
        }
        .navigationTitle("Programs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newCode = freeCodes.first ?? 63
                    showNew = true
                } label: {
                    Label("New program", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showTemplate = true
                } label: {
                    Label("Video template", systemImage: "film")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    booth.locked = true
                } label: {
                    Label("Booth", systemImage: "camera.fill")
                }
            }
        }
        .sheet(isPresented: $showTemplate) {
            NavigationStack {
                ScrollView { PostProcessingStudio().padding() }
                    .navigationTitle("Video template")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showTemplate = false }
                        }
                    }
            }
        }
        .alert("New program", isPresented: $showNew) {
            TextField("Code 0–63", value: $newCode, format: .number.grouping(.never))
                .keyboardType(.numberPad)
            Button("Create") {
                let code = min(63, max(0, newCode))
                guard !usedCodes.contains(code) else { return }
                store.save(Program(number: code, name: "Program \(code)",
                                   railProgram: RailCatalog.hasMove(code) ? code : nil))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Which code? Free codes: \(freeCodes.prefix(12).map(String.init).joined(separator: ", "))\(freeCodes.count > 12 ? "…" : "").")
        }
        .alert("Crew PIN", isPresented: $showPINChange) {
            TextField("4 digits or more", text: $newPIN)
                .keyboardType(.numberPad)
            Button("Save") { booth.setPIN(newPIN) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Needed to leave the booth screen when Support mode is off. Digits only, at least four.")
        }
        .alert("Test the wires", isPresented: $showMeasure) {
            TextField("Rail program", value: $measureCode, format: .number.grouping(.never))
                .keyboardType(.numberPad)
            Button("Fire the rail and watch") {
                runner.measureSignal(railProgram: min(63, max(0, measureCode)))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Which rail program? The rail MOVES; the arm stays still.")
        }
        .navigationDestination(for: Int.self) { number in
            ProgramEditorView(number: number)
        }
        .overlay {
            if store.programs.isEmpty {
                ContentUnavailableView("No programs", systemImage: "tray",
                                       description: Text("The factory programs could not be loaded."))
            }
        }
    }

    private func row(_ program: Program) -> some View {
        HStack(spacing: 16) {
            Text("\(program.number)")
                .font(.title2.monospacedDigit().bold())
                .frame(width: 44, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(program.name).font(.title3)
                Text(program.subtitle).font(.subheadline).foregroundStyle(.secondary)
                if let r = program.railProgram, !RailCatalog.hasMove(r) {
                    Text("The rail has no move stored at \(r) — only the arm will move.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                runner.run(program)
            } label: {
                Label("Run", systemImage: "play.fill")
                    .font(.headline)
                    .frame(width: 90, height: 36)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!arm.connected || runner.running)
        }
        .padding(.vertical, 4)
    }
}

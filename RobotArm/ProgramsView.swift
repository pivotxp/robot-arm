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
    @State private var showTemplate = false
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

            if let l = runner.lastSignal {
                Section("The wires") {
                    Label(String(format: "Last seen: program %d signalled %.2f s after the trigger", l.program, l.latency),
                          systemImage: "waveform.path.ecg")
                }
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
                Menu {
                    Button {
                        newCode = freeCodes.first ?? 63
                        showNew = true
                    } label: {
                        Label("New program", systemImage: "plus")
                    }
                    Button {
                        showMeasure = true
                    } label: {
                        Label("Test the wires", systemImage: "waveform.path.ecg")
                    }
                    .disabled(!rail.connected || !arm.connected || runner.running)
                    Button {
                        showTemplate = true
                    } label: {
                        Label("Video template", systemImage: "film")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
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
        .alert("Test the wires", isPresented: $showMeasure) {
            TextField("Rail program", value: $measureCode, format: .number.grouping(.never))
                .keyboardType(.numberPad)
            Button("Fire the rail and watch") {
                runner.measureSignal(railProgram: min(63, max(0, measureCode)))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs the rail program with the arm standing still, and reports whether the control box raised that number on the six wires and how long after the trigger. The rail MOVES.")
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

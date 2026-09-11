import SwiftUI

/// Screen 2: one program. Name, which rail program to fire, how long the arm waits, and the
/// list of steps. Every change is saved the moment you make it (all edits go straight to the
/// store, which writes the file).
struct ProgramEditorView: View {
    let number: Int
    @ObservedObject private var store = ProgramStore.shared
    @ObservedObject private var arm = ArmLink.shared
    @ObservedObject private var runner = Runner.shared
    @State private var confirmReset = false

    init(number: Int) {
        self.number = number
    }

    /// Reads from the store, and every write saves to disk immediately.
    private var program: Binding<Program> {
        Binding(
            get: { store.program(number) ?? Program(number: number, name: "Program \(number)", railProgram: number) },
            set: { store.save($0) }
        )
    }

    var body: some View {
        let current = program.wrappedValue
        Form {
            Section("Program") {
                LabeledContent("Name") {
                    TextField("Name", text: program.name)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Rail program to start (blank = none)") {
                    TextField("none", value: program.railProgram, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                LabeledContent("Extra seconds the arm waits after the rail signals it (0 = none)") {
                    TextField("0", value: program.armDelay, format: .number.grouping(.never))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                if !current.note.isEmpty {
                    Text(current.note).font(.subheadline).foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(program.steps) { $step in
                    let i = current.steps.firstIndex(where: { $0.id == step.id }) ?? 0
                    NavigationLink {
                        StepEditorView(step: $step, factory: factoryStep(at: i))
                    } label: {
                        StepRow(index: i + 1, step: step)
                    }
                }
                .onDelete { offsets in
                    var p = current
                    p.steps.remove(atOffsets: offsets)
                    store.save(p)
                }
                .onMove { from, to in
                    var p = current
                    p.steps.move(fromOffsets: from, toOffset: to)
                    store.save(p)
                }

                Menu {
                    Button("Joint move") { add(.joint) }
                    Button("Straight line") { add(.line) }
                    Button("Pause") { add(.pause) }
                    Button("Go home") { add(.home) }
                } label: {
                    Label("Add a step", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Steps, in order")
            } footer: {
                Text("Swipe a step left to delete it. Tap Edit to drag steps into a new order.")
            }

            Section {
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Label("Reset this program to factory", systemImage: "arrow.counterclockwise")
                }
                .disabled(store.factoryProgram(number) == nil)
            }
        }
        .navigationTitle("\(number) · \(current.name)")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    runner.run(current)
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!arm.connected || runner.running)
            }
        }
        .confirmationDialog("Throw away your edits to program \(number) and put back the factory version?",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset to factory", role: .destructive) {
                store.resetToFactory(number)
            }
        }
    }

    /// The factory step at the same position, if the factory program has one there.
    private func factoryStep(at i: Int) -> Step? {
        guard let f = store.factoryProgram(number), f.steps.indices.contains(i) else { return nil }
        return f.steps[i]
    }

    private func add(_ kind: StepKind) {
        var p = program.wrappedValue
        var s = Step()
        s.kind = kind
        // Start a new move where the arm is now, or where the last step left it.
        if kind == .joint {
            if arm.joints.count == 5 { s.joints = arm.joints.map { ($0 * 10).rounded() / 10 } }
            else if let last = p.steps.last(where: { $0.kind == .joint }) { s.joints = last.joints }
        }
        if kind == .line, let last = p.steps.last(where: { $0.kind == .line }) { s.pose = last.pose }
        if kind == .pause { s.pauseAfter = 1 }
        p.steps.append(s)
        store.save(p)
    }
}

struct StepRow: View {
    let index: Int
    let step: Step

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index).")
                .font(.headline.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.kind.label).font(.headline)
                Text(step.summary).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                ForEach(step.warnings, id: \.self) { w in
                    Text(w).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

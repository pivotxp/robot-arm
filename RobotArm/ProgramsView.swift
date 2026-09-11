import SwiftUI

/// Screen 1: every program, with a Run button. Tap a row to edit it.
struct ProgramsView: View {
    @ObservedObject private var store = ProgramStore.shared
    @ObservedObject private var arm = ArmLink.shared
    @ObservedObject private var runner = Runner.shared
    @State private var showTemplate = false

    var body: some View {
        List(store.programs) { program in
            NavigationLink(value: program.number) {
                HStack(spacing: 16) {
                    Text("\(program.number)")
                        .font(.title2.monospacedDigit().bold())
                        .frame(width: 44, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(program.name).font(.title3)
                        Text(program.subtitle).font(.subheadline).foregroundStyle(.secondary)
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
        .navigationTitle("Programs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showTemplate = true
                } label: {
                    Label("Video template", systemImage: "film")
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
}

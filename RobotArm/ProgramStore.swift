import Foundation

/// Keeps the programs on disk: one JSON file per program in the app's Documents folder
/// (`program_14.json`), which also shows up in the Files app.
///
/// On first launch every factory program is copied in. After that your edits are never
/// overwritten; "Reset to factory" puts one program back on purpose.
@MainActor
final class ProgramStore: ObservableObject {
    static let shared = ProgramStore()
    private init() {}

    @Published private(set) var programs: [Program] = []

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func fileURL(_ number: Int) -> URL {
        documents.appendingPathComponent(String(format: "program_%02d.json", number))
    }

    private lazy var factory: [Program] = {
        guard let url = Bundle.main.url(forResource: "factory_programs", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(FactoryFile.self, from: data) else { return [] }
        return file.programs
    }()

    func factoryProgram(_ number: Int) -> Program? {
        factory.first { $0.number == number }
    }

    /// Seed any missing factory files, then read everything from disk.
    func load() {
        for p in factory where !FileManager.default.fileExists(atPath: fileURL(p.number).path) {
            write(p)
        }
        var found: [Program] = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? []
        for name in names where name.hasPrefix("program_") && name.hasSuffix(".json") {
            let url = documents.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url),
               let p = try? JSONDecoder().decode(Program.self, from: data) {
                found.append(p)
            }
        }
        programs = found.sorted { $0.number < $1.number }
    }

    func program(_ number: Int) -> Program? {
        programs.first { $0.number == number }
    }

    func save(_ p: Program) {
        write(p)
        if let i = programs.firstIndex(where: { $0.number == p.number }) {
            programs[i] = p
        } else {
            programs.append(p)
            programs.sort { $0.number < $1.number }
        }
    }

    @discardableResult
    func resetToFactory(_ number: Int) -> Program? {
        guard let p = factoryProgram(number) else { return nil }
        save(p)
        return p
    }

    private func write(_ p: Program) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(p) {
            try? data.write(to: fileURL(p.number), options: .atomic)
        }
    }
}

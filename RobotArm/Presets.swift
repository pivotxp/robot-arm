import Foundation
import Combine

// MARK: - Timeline (multi-clip output)

/// One clip in the output timeline. Either the live app recording (a placeholder
/// replaced at capture time) or an imported video file. Each clip's effects recipe
/// is stored separately in UserDefaults under "pivotbot.clip.<id>" so the existing
/// effect controls can edit it by key prefix.
struct TimelineClip: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case recording   // a segment of the live guest recording (full effect controls)
        case uploaded    // an imported video file, played as-is (no effects)
    }
    var id: String = UUID().uuidString
    var kind: Kind = .recording
    var importedFilename: String? = nil   // file within Documents/TimelineClips (uploaded)
    var displayName: String = "Clip"

    var recipeKeyPrefix: String { "pivotbot.clip.\(id)" }
    var isRecording: Bool { kind == .recording }
}

/// Persistent store for the output timeline. Backed by UserDefaults JSON; shared
/// with `TimelineExporter` which reads the same key at export time.
@MainActor
final class TimelineStore: ObservableObject {
    @Published var clips: [TimelineClip] = []

    static let key = "pivotbot.timeline.v1"

    /// Stable id for the live-recording clip so its per-clip recipe keys persist.
    static let recordingClipID = "recording"

    init() { clips = Self.loadClips() }

    /// Non-isolated load used by both the store and TimelineExporter.
    nonisolated static func loadClips() -> [TimelineClip] {
        if let data = UserDefaults.standard.data(forKey: key),
           let arr = try? JSONDecoder().decode([TimelineClip].self, from: data),
           !arr.isEmpty {
            return arr
        }
        return [TimelineClip(id: recordingClipID, kind: .recording, displayName: "App Recorded Video")]
    }

    func save() {
        if let data = try? JSONEncoder().encode(clips) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Add another segment of the guest recording (own trim/speed/reverse controls).
    func addRecordingClip() {
        clips.append(TimelineClip(kind: .recording, displayName: "App Recorded Video"))
        save()
    }

    /// Add an imported video, played as-is.
    func addUploaded(filename: String, displayName: String) {
        clips.append(TimelineClip(kind: .uploaded, importedFilename: filename, displayName: displayName))
        save()
    }

    func delete(_ clip: TimelineClip) {
        clips.removeAll { $0.id == clip.id }
        // Clear its per-clip recipe keys.
        for suffix in ["speed","trimStart","trimEnd","reverse","volume","rotation","posX","posY","sizeWidth","sizeHeight","blendMode","overlayURL","speedRamps"] {
            UserDefaults.standard.removeObject(forKey: "\(clip.recipeKeyPrefix).\(suffix)")
        }
        // Always keep at least one clip so there's an output.
        if clips.isEmpty {
            clips = [TimelineClip(id: Self.recordingClipID, kind: .recording, displayName: "App Recorded Video")]
        }
        save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        clips.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }
}

// MARK: - Codable recipe (mirror of ProcessingRecipe, persistable)

struct PresetRecipe: Codable, Equatable {
    var speedMultiplier: Double = 1.0
    var trimStart: Double = 0
    var trimEnd: Double = 0
    var reverse: Bool = false
    var volume: Double = 1.0
    var rotation: Double = 0
    var posX: Double = 0
    var posY: Double = 0
    var sizeWidth: Double = 100
    var sizeHeight: Double = 100
    var blendMode: String = "Normal"
    var overlayURL: String?
    var speedRamps: [SpeedRamp] = []

    /// Write every field to the per-action @AppStorage keys.
    func writeToDefaults(for action: CaptureAction) {
        let d = UserDefaults.standard
        let k = "pivotbot.\(action.rawValue)"
        d.set(speedMultiplier, forKey: "\(k).speed")
        d.set(trimStart,       forKey: "\(k).trimStart")
        d.set(trimEnd,         forKey: "\(k).trimEnd")
        d.set(reverse,         forKey: "\(k).reverse")
        d.set(volume,          forKey: "\(k).volume")
        d.set(rotation,        forKey: "\(k).rotation")
        d.set(posX,            forKey: "\(k).posX")
        d.set(posY,            forKey: "\(k).posY")
        d.set(sizeWidth,       forKey: "\(k).sizeWidth")
        d.set(sizeHeight,      forKey: "\(k).sizeHeight")
        d.set(blendMode,       forKey: "\(k).blendMode")
        d.set(overlayURL ?? "",forKey: "\(k).overlayURL")
        if speedRamps.isEmpty {
            d.removeObject(forKey: "\(k).speedRamps")
        } else if let data = try? JSONEncoder().encode(speedRamps) {
            d.set(data, forKey: "\(k).speedRamps")
        }
    }

    static func capture(for action: CaptureAction) -> PresetRecipe {
        let r = ProcessingRecipe.load(for: action)
        return PresetRecipe(
            speedMultiplier: r.speedMultiplier,
            trimStart: r.trimStart, trimEnd: r.trimEnd,
            reverse: r.reverse, volume: r.volume,
            rotation: r.rotation,
            posX: r.posX, posY: r.posY,
            sizeWidth: r.sizeWidth, sizeHeight: r.sizeHeight,
            blendMode: r.blendMode, overlayURL: r.overlayURL,
            speedRamps: r.speedRamps
        )
    }
}

// MARK: - Preset model

struct BoothPreset: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    /// Keyed by `CaptureAction.rawValue` ("gif", "burst", "video", "still").
    var recipes: [String: PresetRecipe]
    var isBuiltIn: Bool

    /// Order in which clips appear in the timeline.
    static let clipOrder: [CaptureAction] = [.gif, .burst, .video, .still]
}

// MARK: - Store (ObservableObject backed by UserDefaults)

@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [BoothPreset] = []
    private let key = "pivotbot.presets.v1"

    init() {
        load()
        seedBuiltInIfNeeded()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([BoothPreset].self, from: data) else { return }
        presets = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func seedBuiltInIfNeeded() {
        // Always keep built-ins present (idempotent — if user deleted, returns next launch).
        for builtIn in Self.builtIns {
            if !presets.contains(where: { $0.name == builtIn.name }) {
                presets.append(builtIn)
            }
        }
        save()
    }

    func apply(_ preset: BoothPreset) {
        // Write each preset recipe to its mapped action.
        for action in BoothPreset.clipOrder {
            if let recipe = preset.recipes[action.rawValue] {
                recipe.writeToDefaults(for: action)
            }
        }
    }

    func saveCurrent(as name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var recipes: [String: PresetRecipe] = [:]
        for action in CaptureAction.allCases {
            recipes[action.rawValue] = .capture(for: action)
        }
        presets.removeAll { $0.name == trimmed }
        presets.append(BoothPreset(name: trimmed, recipes: recipes, isBuiltIn: false))
        save()
    }

    func delete(_ preset: BoothPreset) {
        presets.removeAll { $0.id == preset.id }
        save()
    }
}

// MARK: - Built-in presets

extension PresetStore {
    static let builtIns: [BoothPreset] = [.usaa, .usaa2]
}

extension BoothPreset {
    /// USAA preset — matches the three reference clips, in timeline order.
    static let usaa = BoothPreset(
        name: "USAA",
        recipes: [
            // Clip 1 — App Recorded Video (1s)
            "gif": PresetRecipe(
                speedMultiplier: 1.0,
                trimStart: 0.0, trimEnd: 0.25,
                reverse: false,
                volume: 0
            ),
            // Clip 2 — App Recorded Video (4s)
            "burst": PresetRecipe(
                speedMultiplier: 0.25,
                trimStart: 1.0, trimEnd: 2.0,
                reverse: false,
                volume: 0
            ),
            // Clip 3 — App Recorded Video (1.9s)
            "video": PresetRecipe(
                speedMultiplier: 1.0,
                trimStart: 0.0, trimEnd: 0.0, // 0 = use full
                reverse: true,
                volume: 0
            )
        ],
        isBuiltIn: true
    )

    /// USAA 2.0 — cinematic single-capture speed ramp.
    /// Every action runs the same 3-phase ramp on a single recorded clip:
    ///   Phase 1: 0.0–1.0s @ 1.0× (real-time entry)
    ///   Phase 2: 1.0–2.2s @ 0.15× (hyper slow-motion drop → ~8s output)
    ///   Phase 3: 2.2–3.0s @ 1.0× (snap outro rebound)
    /// Total output: ~9.8s from a 3.0s source.
    /// If a PNG overlay is set on the recipe (Settings → Overlay), it's drawn on
    /// every output frame, Normal blend mode.
    static let usaa2 = BoothPreset(
        name: "USAA 2.0",
        recipes: [
            "gif":   Self.usaa2Recipe,
            "burst": Self.usaa2Recipe,
            "video": Self.usaa2Recipe,
            "still": Self.usaa2Recipe
        ],
        isBuiltIn: true
    )

    private static let usaa2Recipe = PresetRecipe(
        speedMultiplier: 1.0,
        trimStart: 0, trimEnd: 0,
        reverse: false,
        volume: 0,
        speedRamps: [
            SpeedRamp(from: 0.0, to: 1.0, multiplier: 1.0),
            SpeedRamp(from: 1.0, to: 2.2, multiplier: 0.15),
            SpeedRamp(from: 2.2, to: 3.0, multiplier: 1.0)
        ]
    )
}

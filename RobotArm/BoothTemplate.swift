import Foundation

/// The booth's video template, copied from the timeline Kyle runs on the old system
/// (screenshots, 2026-09-14). Four clips, 10.4 s in total:
///
///   1. App Recorded Video — source 0 s → 1 s, 1×, volume 0                        = 1.0 s
///   2. App Recorded Video — source 1 s → 3 s, ½× (slow motion), volume 0, overlay  = 4.0 s
///   3. App Recorded Video — source 3 s → 5.4 s, 1×, volume 0                       = 2.4 s
///   4. Uploaded Video — the outro .mp4                                              = 3.0 s
///
/// Everything else at its default: no reverse, position 0/0, rotation 0, size 100/100, blend
/// Normal. So the recording needs to be at least 5.4 s long, and it has to START when the rig
/// starts moving — the template slices the first 5.4 s.
///
/// The two things that are files — clip 2's overlay image and the outro video — cannot be
/// copied from a screenshot. They are added on the iPad: the overlay with the clip's picker in
/// the video template screen, the outro with "Add uploaded video" (it goes on the end, which
/// is where it belongs).
enum BoothTemplate {
    private static let appliedKey = "pivotbot.timeline.boothTemplate.v1"

    /// Seconds of recording the template consumes: the furthest trim end of any recording clip.
    static var recordingSecondsNeeded: Double {
        TimelineStore.loadClips()
            .filter(\.isRecording)
            .map { ProcessingRecipe.load(prefix: $0.recipeKeyPrefix).trimEnd }
            .max() ?? 0
    }

    /// Apply once, on an install whose timeline is still the single default clip.
    static func applyIfFresh() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: appliedKey) else { return }
        let clips = TimelineStore.loadClips()
        let untouched = clips.count == 1 && clips[0].id == TimelineStore.recordingClipID
            && !ProcessingRecipe.load(prefix: clips[0].recipeKeyPrefix).hasAnyEffect
        if untouched { apply() }
        d.set(true, forKey: appliedKey)
    }

    /// Replace the timeline's recording clips with the booth template. Uploaded clips (the
    /// outro) are kept, in order, after them.
    static func apply() {
        let d = UserDefaults.standard
        let kept = TimelineStore.loadClips().filter { !$0.isRecording }
        for c in TimelineStore.loadClips() where c.isRecording { clearRecipe(c.recipeKeyPrefix) }

        let one   = TimelineClip(id: TimelineStore.recordingClipID, kind: .recording, displayName: "App Recorded Video")
        let two   = TimelineClip(id: "recording-slow",  kind: .recording, displayName: "App Recorded Video")
        let three = TimelineClip(id: "recording-end",   kind: .recording, displayName: "App Recorded Video")

        write(one.recipeKeyPrefix,   trimStart: 0, trimEnd: 1.0, speed: 1.0)
        write(two.recipeKeyPrefix,   trimStart: 1, trimEnd: 3.0, speed: 0.5)
        write(three.recipeKeyPrefix, trimStart: 3, trimEnd: 5.4, speed: 1.0)

        let clips = [one, two, three] + kept
        if let data = try? JSONEncoder().encode(clips) {
            d.set(data, forKey: TimelineStore.key)
        }
        Log.write("video template: booth template applied (1 s · 4 s at ½× · 2.4 s, then \(kept.count) uploaded clip(s))")
    }

    private static func write(_ k: String, trimStart: Double, trimEnd: Double, speed: Double) {
        let d = UserDefaults.standard
        d.set(speed,     forKey: "\(k).speed")
        d.set(trimStart, forKey: "\(k).trimStart")
        d.set(trimEnd,   forKey: "\(k).trimEnd")
        d.set(false,     forKey: "\(k).reverse")
        d.set(0.0,       forKey: "\(k).volume")        // "Recording volume 0" on every clip
        d.set(0.0,       forKey: "\(k).rotation")
        d.set(0.0,       forKey: "\(k).posX")
        d.set(0.0,       forKey: "\(k).posY")
        d.set(100.0,     forKey: "\(k).sizeWidth")
        d.set(100.0,     forKey: "\(k).sizeHeight")
        d.set("Normal",  forKey: "\(k).blendMode")
        d.removeObject(forKey: "\(k).speedRamps")
        // overlayURL is left as it is: a picked overlay survives re-applying the template.
    }

    private static func clearRecipe(_ k: String) {
        let d = UserDefaults.standard
        for s in ["speed", "trimStart", "trimEnd", "reverse", "volume", "rotation", "posX", "posY",
                  "sizeWidth", "sizeHeight", "blendMode", "speedRamps"] {
            d.removeObject(forKey: "\(k).\(s)")
        }
    }

    /// "1 s · 4 s at ½× · 2.4 s · outro 3 s = 10.4 s", from what is actually stored.
    static var summary: String {
        let clips = TimelineStore.loadClips()
        var parts: [String] = []
        var total = 0.0
        for c in clips {
            if c.isRecording {
                let r = ProcessingRecipe.load(prefix: c.recipeKeyPrefix)
                let src = max(0, r.trimEnd - r.trimStart)
                let out = r.speedMultiplier > 0 ? src / r.speedMultiplier : src
                total += out
                parts.append(r.speedMultiplier == 1 ? String(format: "%.3g s", out)
                                                    : String(format: "%.3g s at %@×", out, speedName(r.speedMultiplier)))
            } else {
                parts.append(c.importedFilename == nil ? "outro (not imported)" : "outro")
            }
        }
        return parts.joined(separator: " · ") + (total > 0 ? String(format: " — %.1f s of recording", total) : "")
    }

    private static func speedName(_ s: Double) -> String {
        switch s {
        case 0.5: return "½"
        case 0.25: return "¼"
        case 1.0 / 3.0: return "⅓"
        default: return String(format: "%.3g", s)
        }
    }
}

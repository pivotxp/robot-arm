import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Studio (functional multi-clip timeline)

struct PostProcessingStudio: View {
    @StateObject private var timeline = TimelineStore()
    @AppStorage("pivotbot.recordingSeconds") private var recordingSeconds = 5.0
    @State private var selectedClipID: String = TimelineStore.recordingClipID
    @State private var advancedOpen: Bool = true
    @State private var showImporter = false
    /// Bump to force StudioControls to fully re-create when the selected clip
    /// changes so its @AppStorage values are re-read fresh.
    @State private var refreshNonce: Int = 0
    /// Cached durations (seconds) of imported clips, loaded async.
    @State private var uploadedDurations: [String: Double] = [:]
    /// Bumped on any UserDefaults change so the live total recomputes as the
    /// per-clip trim/speed sliders move.
    @State private var recomputeToken: Int = 0

    private let accent = Color(red: 0.32, green: 0.43, blue: 0.97)

    private var selectedClip: TimelineClip? {
        timeline.clips.first { $0.id == selectedClipID } ?? timeline.clips.first
    }

    var body: some View {
        VStack(spacing: 16) {
            timelineCard
            advancedRow
            if advancedOpen, let clip = selectedClip {
                if clip.isRecording {
                    StudioControls(keyPrefix: clip.recipeKeyPrefix, previewURL: nil, rangeMax: recordingSeconds)
                        .id("\(clip.id)-\(refreshNonce)")
                } else {
                    uploadedClipPanel(clip)
                }
            }
        }
        .onAppear { loadUploadedDurations() }
        .onChange(of: timeline.clips) { _, clips in
            if !clips.contains(where: { $0.id == selectedClipID }) {
                selectedClipID = clips.first?.id ?? TimelineStore.recordingClipID
                refreshNonce += 1
            }
            loadUploadedDurations()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            recomputeToken &+= 1
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
    }

    // MARK: - Uploaded clip panel (played as-is, no effects)

    private func uploadedClipPanel(_ clip: TimelineClip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "film")
                    .font(.system(size: 20))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                    Text("Uploaded clip — plays as-is (no speed, trim, or overlay).")
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.inkMuted)
                }
                Spacer()
                Text(durationLabel(uploadedDurations[clip.id]))
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(Brand.ink)
                    .monospacedDigit()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: - Timeline card

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Video Timeline")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.ink)
                Spacer()
                totalBadge
                Menu {
                    Button {
                        Haptics.medium()
                        timeline.addRecordingClip()
                        selectedClipID = timeline.clips.last?.id ?? selectedClipID
                        refreshNonce += 1
                    } label: {
                        Label("App Recorded Video", systemImage: "record.circle")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Upload Video", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Add Element")
                    }
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Capsule().fill(accent))
                }
                .menuStyle(.borderlessButton)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(timeline.clips.enumerated()), id: \.element.id) { idx, clip in
                        clipCard(index: idx + 1, clip: clip)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }

            Text("Clips play left → right. Tap a clip to edit it. Add multiple “App Recorded Video” clips to use different segments/speeds of the same guest recording; add “Upload Video” for an end card. The recording clips are filled in by each guest's capture.")
                .font(.caption2)
                .foregroundStyle(Brand.inkMuted)
        }
        .padding(14)
        .background(cardBackground)
    }

    private var totalBadge: some View {
        let _ = recomputeToken   // re-read trigger
        return HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 12))
                .foregroundStyle(Brand.inkMuted)
            Text("Output")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.inkMuted)
            Text(durationLabel(totalOutputDuration))
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(totalOutputDuration > 30 ? Brand.red : Brand.ink)
                .monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().strokeBorder(accent, lineWidth: 1))
    }

    // MARK: - Durations

    private func durationLabel(_ seconds: Double?) -> String {
        guard let s = seconds, s > 0 else { return "—" }
        return String(format: "%.1fs", s)
    }

    /// Output duration of one app-recorded clip given its trim + speed. Source
    /// length is the configured recording length (the live clip is that long).
    private func recordingClipDuration(_ clip: TimelineClip) -> Double {
        let r = recordingSeconds
        let recipe = ProcessingRecipe.load(prefix: clip.recipeKeyPrefix)
        // Round In/Out to the same 0.1 grid the slider/readout use so the shown
        // duration matches the displayed In/Out exactly (no sub-tenth drift).
        let inS = snap01(min(max(0, recipe.trimStart), r))
        let outS = snap01(recipe.trimEnd > 0 ? min(recipe.trimEnd, r) : r)
        let segment = max(0, outS - inS)
        return segment / max(0.01, recipe.speedMultiplier)
    }

    private func snap01(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    private func clipDuration(_ clip: TimelineClip) -> Double {
        clip.isRecording ? recordingClipDuration(clip) : (uploadedDurations[clip.id] ?? 0)
    }

    private var totalOutputDuration: Double {
        timeline.clips.reduce(0) { $0 + clipDuration($1) }
    }

    private func loadUploadedDurations() {
        for clip in timeline.clips where !clip.isRecording {
            guard uploadedDurations[clip.id] == nil, let name = clip.importedFilename else { continue }
            let url = TimelineExporter.clipsDir().appendingPathComponent(name)
            Task {
                let asset = AVURLAsset(url: url)
                let secs = (try? await asset.load(.duration))?.seconds ?? 0
                await MainActor.run { uploadedDurations[clip.id] = secs.isFinite ? secs : 0 }
            }
        }
    }

    private func clipCard(index: Int, clip: TimelineClip) -> some View {
        let isSelected = clip.id == selectedClipID
        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: isSelected ? [] : [4, 4]))
                    .foregroundStyle(isSelected ? accent : Brand.inkMuted.opacity(0.45))
                    .frame(width: 150, height: 70)
                    .overlay(
                        VStack(spacing: 2) {
                            Text(clip.displayName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Brand.ink)
                                .lineLimit(1)
                            Text(clip.isRecording ? "app recording" : "uploaded")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(Brand.inkMuted)
                            Text(durationLabel(clipDuration(clip)))
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(accent)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 8)
                    )
                // Numbered badge
                ZStack {
                    Circle().fill(.white)
                        .overlay(Circle().strokeBorder(isSelected ? accent : Brand.inkMuted.opacity(0.6), lineWidth: 2))
                        .frame(width: 22, height: 22)
                    Text("\(index)")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Brand.ink)
                }
                .offset(x: -62, y: -10)
                // Delete — any clip can be removed; the store always keeps at
                // least one so there's an output. Hidden when it's the last clip.
                if timeline.clips.count > 1 {
                    Button {
                        Haptics.light()
                        timeline.delete(clip)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Brand.red)
                            .background(Circle().fill(.white).padding(2))
                            .frame(width: 34, height: 34)   // generous tap target
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 8, y: -12)
                }
            }
            // Reorder controls on the selected clip
            if isSelected {
                HStack(spacing: 10) {
                    moveButton(systemImage: "arrow.left", disabled: index == 1) { move(clip, -1) }
                    moveButton(systemImage: "arrow.right", disabled: index == timeline.clips.count) { move(clip, +1) }
                }
            } else {
                Color.clear.frame(height: 30)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedClipID = clip.id
            refreshNonce += 1
        }
    }

    private func moveButton(systemImage: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(disabled ? Brand.inkMuted.opacity(0.4) : Brand.ink)
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func move(_ clip: TimelineClip, _ delta: Int) {
        guard let i = timeline.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        let j = i + delta
        guard j >= 0, j < timeline.clips.count else { return }
        Haptics.selection()
        timeline.clips.swapAt(i, j)
        timeline.save()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let src = urls.first else { return }
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        let dir = TimelineExporter.clipsDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = src.pathExtension.isEmpty ? "mov" : src.pathExtension
        let filename = "clip-\(UUID().uuidString.prefix(8)).\(ext)"
        let dest = dir.appendingPathComponent(filename)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            let name = src.deletingPathExtension().lastPathComponent
            timeline.addUploaded(filename: filename, displayName: name.isEmpty ? "Uploaded Clip" : name)
            selectedClipID = timeline.clips.last?.id ?? selectedClipID
            refreshNonce += 1
            loadUploadedDurations()
            Haptics.success()
        } catch {
            Haptics.error()
        }
    }

    // MARK: - Advanced expander

    private var advancedRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { advancedOpen.toggle() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clip Effects")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                    Text("Trim, speed, volume, reverse and overlay for the selected clip")
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.inkMuted)
                }
                Spacer()
                Image(systemName: advancedOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Brand.inkMuted)
            }
            .padding(14)
            .background(cardBackground)
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.05), lineWidth: 1))
    }
}

// MARK: - Studio Controls (the 3 columns) — edits one clip's recipe by key prefix

struct StudioControls: View {
    let keyPrefix: String
    let previewURL: URL?
    /// Length (seconds) of this clip's source — sets the playback-range slider's
    /// max so In/Out map to the real footage.
    var rangeMax: Double = 30

    @AppStorage private var speed: Double
    @AppStorage private var trimStart: Double
    @AppStorage private var trimEnd: Double
    @AppStorage private var reverse: Bool
    @AppStorage private var volume: Double
    @AppStorage private var rotation: Double
    @AppStorage private var posX: Double
    @AppStorage private var posY: Double
    @AppStorage private var sizeWidth: Double
    @AppStorage private var sizeHeight: Double
    @AppStorage private var blendMode: String
    @AppStorage private var overlayURL: String

    @State private var sourceURL: URL?
    @State private var undoStack: [ProcessingRecipe] = []
    @State private var suppressNextPush: Bool = false

    init(keyPrefix: String, previewURL: URL?, rangeMax: Double = 30) {
        self.keyPrefix = keyPrefix
        self.previewURL = previewURL
        self.rangeMax = rangeMax
        let k = keyPrefix
        _speed      = AppStorage(wrappedValue: 1.0,  "\(k).speed")
        _trimStart  = AppStorage(wrappedValue: 0.0,  "\(k).trimStart")
        _trimEnd    = AppStorage(wrappedValue: 0.0,  "\(k).trimEnd")
        _reverse    = AppStorage(wrappedValue: false,"\(k).reverse")
        _volume     = AppStorage(wrappedValue: 1.0,  "\(k).volume")
        _rotation   = AppStorage(wrappedValue: 0.0,  "\(k).rotation")
        _posX       = AppStorage(wrappedValue: 0.0,  "\(k).posX")
        _posY       = AppStorage(wrappedValue: 0.0,  "\(k).posY")
        _sizeWidth  = AppStorage(wrappedValue: 100.0,"\(k).sizeWidth")
        _sizeHeight = AppStorage(wrappedValue: 100.0,"\(k).sizeHeight")
        _blendMode  = AppStorage(wrappedValue: "Normal", "\(k).blendMode")
        _overlayURL = AppStorage(wrappedValue: "",   "\(k).overlayURL")
    }

    private var liveRecipe: ProcessingRecipe {
        var r = ProcessingRecipe()
        r.speedMultiplier = speed; r.trimStart = trimStart; r.trimEnd = trimEnd
        r.reverse = reverse; r.volume = volume; r.rotation = rotation
        r.posX = posX; r.posY = posY; r.sizeWidth = sizeWidth; r.sizeHeight = sizeHeight
        r.blendMode = blendMode; r.overlayURL = overlayURL.isEmpty ? nil : overlayURL
        return r
    }

    /// "Out" point for the range slider. The recipe stores 0 to mean "play to the
    /// end", so the slider shows the full length and snapping the thumb to the far
    /// edge stores 0 again.
    private var outBinding: Binding<Double> {
        Binding(
            get: { trimEnd == 0 ? rangeMax : min(trimEnd, rangeMax) },
            set: { newVal in trimEnd = newVal >= rangeMax - 0.05 ? 0 : max(0, newVal) }
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            toolbar
            RecipePreviewPlayer(sourceURL: sourceURL, recipe: liveRecipe)
                .frame(maxHeight: 220)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    playback; frame; overlay
                }
                VStack(spacing: 14) { playback; frame; overlay }
            }
        }
        .onAppear { sourceURL = previewURL ?? PreviewSample.bestAvailableURL() }
        .onChange(of: liveRecipe) { old, _ in
            if suppressNextPush {
                suppressNextPush = false
                return
            }
            undoStack.append(old)
            if undoStack.count > 50 { undoStack.removeFirst() }
        }
    }

    // MARK: - Undo / Reset toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .heavy))
                    .kerning(1)
                    .foregroundStyle(undoStack.isEmpty ? Brand.inkMuted.opacity(0.5) : Brand.ink)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color(white: 0.96)))
            }
            .buttonStyle(.plain)
            .disabled(undoStack.isEmpty)

            Button {
                reset()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .heavy))
                    .kerning(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Brand.red))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(undoStack.count) change\(undoStack.count == 1 ? "" : "s") in history")
                .font(.system(size: 11, weight: .heavy)).kerning(1)
                .foregroundStyle(Brand.inkMuted)
        }
    }

    private func undo() {
        guard let prev = undoStack.popLast() else { return }
        Haptics.light()
        suppressNextPush = true
        apply(prev)
    }

    private func reset() {
        let current = liveRecipe
        if current != ProcessingRecipe() {
            undoStack.append(current)
            if undoStack.count > 50 { undoStack.removeFirst() }
        }
        Haptics.medium()
        suppressNextPush = true
        apply(ProcessingRecipe())
    }

    private func apply(_ r: ProcessingRecipe) {
        speed      = r.speedMultiplier
        trimStart  = r.trimStart
        trimEnd    = r.trimEnd
        reverse    = r.reverse
        volume     = r.volume
        rotation   = r.rotation
        posX       = r.posX
        posY       = r.posY
        sizeWidth  = r.sizeWidth
        sizeHeight = r.sizeHeight
        blendMode  = r.blendMode
        overlayURL = r.overlayURL ?? ""
    }

    // MARK: - Playback column

    private var playback: some View {
        column("Playback") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Reverse playback")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.ink)
                    Spacer()
                    Button {
                        reverse.toggle()
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Brand.inkMuted, lineWidth: 1)
                                .frame(width: 22, height: 22)
                            if reverse {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .heavy))
                                    .foregroundStyle(Brand.red)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.black.opacity(0.15), lineWidth: 1))

                // Playback range (in / out trim) — dual-thumb slider
                VStack(alignment: .leading, spacing: 6) {
                    Text("Playback range")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.inkMuted)
                    RangeSlider(low: $trimStart, high: outBinding, bounds: 0...max(rangeMax, 0.5))
                    HStack {
                        Text("In " + String(format: "%.1fs", trimStart))
                            .font(.system(size: 10, weight: .heavy)).foregroundStyle(Brand.ink)
                        Spacer()
                        Text(trimEnd == 0
                             ? "Out " + String(format: "%.1fs", rangeMax) + " (end)"
                             : "Out " + String(format: "%.1fs", min(trimEnd, rangeMax)))
                            .font(.system(size: 10, weight: .heavy)).foregroundStyle(Brand.ink)
                    }
                }

                // Speed multiplier
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speed multiplier")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.inkMuted)
                    SnapSpeedSlider(value: $speed)
                }

                // Recording volume
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recording volume")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.inkMuted)
                    Slider(value: $volume, in: 0...1)
                        .tint(Color(red: 0.32, green: 0.43, blue: 0.97))
                    HStack {
                        Text("0").font(.system(size: 10)).foregroundStyle(Brand.inkMuted)
                        Spacer()
                        Text("100").font(.system(size: 10)).foregroundStyle(Brand.inkMuted)
                    }
                }
            }
        }
    }

    // MARK: - Video Frame column

    private var frame: some View {
        column("Video Frame") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Set Position:")
                        .font(.system(size: 13)).foregroundStyle(Brand.ink)
                    HStack(spacing: 14) {
                        labeledNumber("X%:", value: $posX, range: -100...100)
                        labeledNumber("Y%:", value: $posY, range: -100...100)
                        labeledNumber("Rotation °:", value: $rotation, range: -180...180)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Set Size:")
                        .font(.system(size: 13)).foregroundStyle(Brand.ink)
                    HStack(spacing: 14) {
                        labeledNumber("Width%:",  value: $sizeWidth,  range: 10...200)
                        labeledNumber("Height%:", value: $sizeHeight, range: 10...200)
                    }
                }
                Text("Position/size are preview-only — not yet baked into exported file.")
                    .font(.caption2).foregroundStyle(Brand.red.opacity(0.85))
            }
        }
    }

    private func labeledNumber(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11)).foregroundStyle(Brand.inkMuted)
            NumberArrowInput(value: value, range: range)
        }
    }

    // MARK: - Overlay column

    private var overlay: some View {
        column("Overlay") {
            OverlayColumn(blendMode: $blendMode, overlayURL: $overlayURL)
        }
    }

    // MARK: - Column wrapper

    private func column<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.ink)
                .frame(maxWidth: .infinity)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Snap slider for speed multiplier

struct SnapSpeedSlider: View {
    @Binding var value: Double
    private let steps: [Double] = [0.125, 1.0/6.0, 0.25, 1.0/3.0, 0.5, 1.0, 1.25, 1.5, 2.0, 3.0]
    private let labels = ["⅛x","⅙x","¼x","⅓x","½x","1x","1.25x","1.5x","2x","3x"]

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { Double(steps.firstIndex(where: { abs($0 - value) < 0.001 }) ?? 5) },
                set: { newIdx in
                    let clamped = max(0, min(steps.count - 1, Int(newIdx.rounded())))
                    value = steps[clamped]
                }
            ), in: 0...Double(steps.count - 1), step: 1)
            .tint(Color(red: 0.32, green: 0.43, blue: 0.97))

            HStack(spacing: 0) {
                ForEach(0..<labels.count, id: \.self) { i in
                    Text(labels[i])
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(value == steps[i] ? Brand.red : Brand.inkMuted)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Dual-thumb range slider (In / Out)

struct RangeSlider: View {
    @Binding var low: Double
    @Binding var high: Double
    let bounds: ClosedRange<Double>
    var step: Double = 0.1
    var tint: Color = Color(red: 0.32, green: 0.43, blue: 0.97)

    private let thumb: CGFloat = 24

    private var span: Double { max(bounds.upperBound - bounds.lowerBound, 0.0001) }

    private func centerX(_ v: Double, usable: CGFloat) -> CGFloat {
        let clamped = min(max(v, bounds.lowerBound), bounds.upperBound)
        return thumb / 2 + CGFloat((clamped - bounds.lowerBound) / span) * usable
    }
    private func value(atX x: CGFloat, usable: CGFloat) -> Double {
        let frac = min(max(x - thumb / 2, 0), usable) / usable
        let raw = bounds.lowerBound + Double(frac) * span
        // Snap to clean increments so In/Out land on exact seconds.
        let snapped = (raw / step).rounded() * step
        return min(max(bounds.lowerBound, snapped), bounds.upperBound)
    }

    var body: some View {
        GeometryReader { geo in
            track(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: thumb)
    }

    private func track(width: CGFloat, height: CGFloat) -> some View {
        let usable = max(width - thumb, 1)
        let midY = height / 2
        let lowX = centerX(low, usable: usable)
        let highX = centerX(high, usable: usable)
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.black.opacity(0.12))
                .frame(width: width, height: 4)
                .position(x: width / 2, y: midY)
            Capsule().fill(tint)
                .frame(width: max(0, highX - lowX), height: 4)
                .position(x: (lowX + highX) / 2, y: midY)

            thumbView
                .position(x: lowX, y: midY)
                .gesture(DragGesture().onChanged { g in
                    low = min(max(bounds.lowerBound, value(atX: g.location.x, usable: usable)), high)
                })
            thumbView
                .position(x: highX, y: midY)
                .gesture(DragGesture().onChanged { g in
                    high = max(min(bounds.upperBound, value(atX: g.location.x, usable: usable)), low)
                })
        }
    }

    private var thumbView: some View {
        Circle().fill(.white)
            .overlay(Circle().strokeBorder(tint, lineWidth: 2))
            .frame(width: thumb, height: thumb)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}

// MARK: - Number input with up/down arrows

struct NumberArrowInput: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1

    var body: some View {
        HStack(spacing: 2) {
            TextField("", value: Binding(
                get: { value },
                set: { value = max(range.lowerBound, min(range.upperBound, $0)) }
            ), format: .number)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.center)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 48, height: 30)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.2), lineWidth: 1))
            VStack(spacing: 0) {
                Button {
                    if value + step <= range.upperBound { value += step }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Brand.ink)
                        .frame(width: 14, height: 14)
                        .background(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button {
                    if value - step >= range.lowerBound { value -= step }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Brand.ink)
                        .frame(width: 14, height: 14)
                        .background(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

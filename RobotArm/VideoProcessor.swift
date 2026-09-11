import Foundation
import UIKit
@preconcurrency import AVFoundation
import CoreImage

/// One region in a multi-region speed ramp: source seconds [from, to] played at
/// `multiplier`. When `speedRamps` is non-empty on the recipe, it replaces the
/// single `speedMultiplier` + `trimStart/trimEnd` behavior.
struct SpeedRamp: Codable, Equatable {
    var from: Double      // seconds from start of source
    var to: Double        // seconds from start of source
    var multiplier: Double // 0.01...10 — output duration = (to-from)/multiplier
}

/// Per-action post-processing recipe (loaded from @AppStorage keys).
struct ProcessingRecipe: Equatable {
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

    /// Multi-region speed ramp. When non-empty, runs the ramped export pipeline
    /// (cinematic phase-by-phase speed) instead of the single-speed path.
    var speedRamps: [SpeedRamp] = []

    var hasAnyEffect: Bool {
        speedMultiplier != 1.0 ||
        trimStart > 0 || trimEnd > 0 ||
        reverse ||
        volume != 1.0 ||
        rotation != 0 ||
        !speedRamps.isEmpty ||
        (overlayURL?.isEmpty == false)
    }

    static func load(for action: CaptureAction) -> ProcessingRecipe {
        load(prefix: "pivotbot.\(action.rawValue)")
    }

    /// Load a recipe from any UserDefaults key prefix (used for per-timeline-clip
    /// recipes stored under "pivotbot.clip.<id>").
    static func load(prefix key: String) -> ProcessingRecipe {
        let d = UserDefaults.standard
        var r = ProcessingRecipe()
        r.speedMultiplier = d.object(forKey: "\(key).speed")       as? Double ?? 1.0
        r.trimStart       = d.double(forKey: "\(key).trimStart")
        r.trimEnd         = d.double(forKey: "\(key).trimEnd")
        r.reverse         = d.bool(forKey:   "\(key).reverse")
        r.volume          = d.object(forKey: "\(key).volume")      as? Double ?? 1.0
        r.rotation        = d.double(forKey: "\(key).rotation")
        r.posX            = d.double(forKey: "\(key).posX")
        r.posY            = d.double(forKey: "\(key).posY")
        r.sizeWidth       = d.object(forKey: "\(key).sizeWidth")   as? Double ?? 100
        r.sizeHeight      = d.object(forKey: "\(key).sizeHeight")  as? Double ?? 100
        r.blendMode       = d.string(forKey: "\(key).blendMode") ?? "Normal"
        r.overlayURL      = d.string(forKey: "\(key).overlayURL")
        if let data = d.data(forKey: "\(key).speedRamps"),
           let ramps = try? JSONDecoder().decode([SpeedRamp].self, from: data) {
            r.speedRamps = ramps
        }
        return r
    }
}

enum VideoProcessorError: Error, LocalizedError {
    case noVideoTrack
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "Recorded file had no video track"
        case .exportFailed(let m): return "Export: \(m)"
        }
    }
}

enum VideoProcessor {
    /// Apply the recipe to `inputURL` and return the URL of the processed mp4.
    /// If the recipe has no effects, returns `inputURL` unchanged (no-op) — unless
    /// `normalize` is set, in which case it always re-renders into the landscape
    /// 1920×1080 canvas (used by the timeline so every clip matches before concat).
    static func process(inputURL: URL, recipe: ProcessingRecipe, normalize: Bool = false) async throws -> URL {
        guard recipe.hasAnyEffect || normalize else { return inputURL }

        // Multi-region speed ramping path (cinematic presets like USAA 2.0).
        if !recipe.speedRamps.isEmpty {
            return try await exportRamped(inputURL: inputURL, recipe: recipe)
        }

        // Reverse playback, three safe passes with each effect applied exactly once:
        //   1. trim (+mute) via composition — at 1× so the reverse pass sees the
        //      smallest possible frame count,
        //   2. overlay + 1920×1080 normalize FIRST (the overlay is static, so
        //      burning it before reversing is equivalent) — this downscales 4K
        //      sources so the in-memory reverse holds 1080p frames, not 4K,
        //   3. reverse the frames — the speed multiplier is applied HERE (in the
        //      retiming) and nowhere else.
        if recipe.reverse {
            var trimOnly = recipe
            trimOnly.speedMultiplier = 1.0
            var working = inputURL
            var intermediate: URL? = nil
            if recipe.trimStart > 0 || recipe.trimEnd > 0 || recipe.volume <= 0.01 {
                working = try await exportTrimSpeed(inputURL: inputURL, recipe: trimOnly)
                intermediate = working
            }
            let normalized = try await exportOverlayNormalize(inputURL: working, overlayPath: recipe.overlayURL)
            if let intermediate { try? FileManager.default.removeItem(at: intermediate) }
            let final = try await exportReverse(inputURL: normalized, recipe: recipe)
            try? FileManager.default.removeItem(at: normalized)
            return final
        }

        // Common path: trim + speed + overlay via AVAssetExportSession. The
        // system-managed exporter coexists with the (external) camera; the manual
        // AVAssetWriter path below stalls when it can't grab a hardware encoder.
        return try await exportComposition(inputURL: inputURL, recipe: recipe)
    }

    // MARK: - Trim + speed + overlay via AVAssetExportSession (encoder-safe)

    private static func exportComposition(inputURL: URL, recipe: ProcessingRecipe) async throws -> URL {
        // Two passes. The Core Image overlay export (-16976) aborts both when the
        // composition has scaleTimeRange (speed) AND when it runs directly on the
        // raw external-camera recording. So Pass 1 ALWAYS re-encodes to a clean MP4
        // whenever there's an overlay or any time edit; Pass 2 composites the
        // overlay onto that clean clip (filter never touches the raw recording).
        let hasOverlay = !(recipe.overlayURL ?? "").isEmpty
        let needsTimeEdit = recipe.trimStart > 0 || recipe.trimEnd > 0
            || recipe.speedMultiplier != 1.0 || recipe.volume <= 0.01

        var working = inputURL
        var intermediate: URL? = nil
        if needsTimeEdit || hasOverlay {
            working = try await exportTrimSpeed(inputURL: inputURL, recipe: recipe)
            intermediate = working
        }
        let final = try await exportOverlayNormalize(inputURL: working, overlayPath: recipe.overlayURL)
        if let intermediate { try? FileManager.default.removeItem(at: intermediate) }
        return final
    }

    /// Pass 1 — trim + speed (+ mute) via AVMutableComposition. No video filter,
    /// so `scaleTimeRange` is safe. Re-encodes to a temp clip at source size.
    private static func exportTrimSpeed(inputURL: URL, recipe: ProcessingRecipe) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        let assetDuration = try await asset.load(.duration)
        guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoProcessorError.noVideoTrack
        }

        func snap01(_ x: Double) -> Double { (x * 10).rounded() / 10 }
        let startSec = snap01(max(0, recipe.trimStart))
        let endSec = recipe.trimEnd > 0 ? snap01(min(recipe.trimEnd, assetDuration.seconds)) : assetDuration.seconds
        guard endSec > startSec else { throw VideoProcessorError.exportFailed("Empty trim range") }

        let ts: CMTimeScale = 600
        let trimRange = CMTimeRange(
            start: CMTime(seconds: startSec, preferredTimescale: ts),
            duration: CMTime(seconds: endSec - startSec, preferredTimescale: ts)
        )

        let composition = AVMutableComposition()
        guard let vTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoProcessorError.exportFailed("Could not create composition track")
        }
        try vTrack.insertTimeRange(trimRange, of: srcVideo, at: .zero)
        vTrack.preferredTransform = try await srcVideo.load(.preferredTransform)

        // Audio (skip when muted so volume=0 actually silences the clip).
        if recipe.volume > 0.01,
           let srcAudio = try await asset.loadTracks(withMediaType: .audio).first,
           let aTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? aTrack.insertTimeRange(trimRange, of: srcAudio, at: .zero)
        }

        let speed = max(0.01, recipe.speedMultiplier)
        if speed != 1.0 {
            let inserted = CMTime(seconds: endSec - startSec, preferredTimescale: ts)
            let scaled = CMTime(seconds: (endSec - startSec) / speed, preferredTimescale: ts)
            composition.scaleTimeRange(CMTimeRange(start: .zero, duration: inserted), toDuration: scaled)
        }

        let outURL = tempURL("pb-ts")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoProcessorError.exportFailed("Could not create exporter")
        }
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        guard export.status == .completed else {
            throw VideoProcessorError.exportFailed("PASS1 trim/speed — \(export.error?.localizedDescription ?? "status \(export.status.rawValue)")")
        }
        return outURL
    }

    /// Pass 2 — overlay + aspect-fill into the 1920×1080 landscape canvas via a
    /// Core Image filter handler. No time scaling here, so the filter export is
    /// reliable.
    private static func exportOverlayNormalize(inputURL: URL, overlayPath: String?) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        let overlay = overlayCIImage(overlayPath)
        let target = renderSize
        let videoComposition = AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage
            let ext = source.extent
            let scale = max(target.width / max(ext.width, 1), target.height / max(ext.height, 1))
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let sExt = scaled.extent
            let centered = scaled.transformed(by: CGAffineTransform(
                translationX: (target.width - sExt.width) / 2 - sExt.minX,
                y: (target.height - sExt.height) / 2 - sExt.minY))
            var output = centered.cropped(to: CGRect(origin: .zero, size: target))
            if let overlay {
                let osx = target.width / max(overlay.extent.width, 1)
                let osy = target.height / max(overlay.extent.height, 1)
                output = overlay.transformed(by: CGAffineTransform(scaleX: osx, y: osy)).composited(over: output)
            }
            request.finish(with: output, context: nil)
        }
        videoComposition.renderSize = target

        let outURL = tempURL("pb-ov")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            throw VideoProcessorError.exportFailed("Could not create exporter")
        }
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        guard export.status == .completed else {
            throw VideoProcessorError.exportFailed("PASS2 overlay — \(export.error?.localizedDescription ?? "status \(export.status.rawValue)")")
        }
        return outURL
    }

    private static func tempURL(_ prefix: String) -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: u)
        return u
    }

    private static func overlayCIImage(_ path: String?) -> CIImage? {
        guard let path, !path.isEmpty else { return nil }
        return CIImage(contentsOf: URL(fileURLWithPath: path))
    }

    // MARK: - Speed + trim via AVAssetReader/Writer (reliable on iPad 26)

    private static func exportTrim(inputURL: URL, recipe: ProcessingRecipe) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw VideoProcessorError.noVideoTrack }
        let assetDuration = try await asset.load(.duration)

        // Round In/Out to the 0.1s grid the editor snaps to, so the exported
        // segment length matches the duration shown in the studio exactly.
        func snap01(_ x: Double) -> Double { (x * 10).rounded() / 10 }
        let startSec = snap01(max(0, recipe.trimStart))
        let endSec: Double = recipe.trimEnd > 0
            ? snap01(min(recipe.trimEnd, assetDuration.seconds))
            : assetDuration.seconds
        guard endSec > startSec else { throw VideoProcessorError.exportFailed("Empty trim range") }

        let scale: CMTimeScale = 600
        let trimRange = CMTimeRange(
            start: CMTime(seconds: startSec, preferredTimescale: scale),
            duration: CMTime(seconds: endSec - startSec, preferredTimescale: scale)
        )

        let outputSize = renderSize
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-processed-\(UUID().uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        // -- Reader for video frames within trim range --
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = trimRange
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        // -- Audio reader (if present) --
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTracks.first {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                audioOutput = out
            }
        }

        // -- Writer (1920×1080 landscape output, pre-rendered, identity transform) --
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height)
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = .identity
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height)
            ]
        )
        guard writer.canAdd(videoInput) else { throw VideoProcessorError.exportFailed("can't add video input") }
        writer.add(videoInput)

        // Audio writer input (passes through encoded audio at proper speed).
        var audioInput: AVAssetWriterInput?
        if let audioTrack = audioTracks.first, audioOutput != nil {
            let formatDescriptions = try await audioTrack.load(.formatDescriptions)
            if let firstFormat = formatDescriptions.first {
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                            sourceFormatHint: firstFormat)
                ai.expectsMediaDataInRealTime = false
                if writer.canAdd(ai) {
                    writer.add(ai)
                    audioInput = ai
                }
            }
        }

        guard reader.startReading() else {
            throw VideoProcessorError.exportFailed(reader.error?.localizedDescription ?? "reader start")
        }
        guard writer.startWriting() else {
            throw VideoProcessorError.exportFailed(writer.error?.localizedDescription ?? "writer start")
        }
        writer.startSession(atSourceTime: .zero)

        let speed = max(0.01, recipe.speedMultiplier)
        let trimStartTime = trimRange.start
        let volume = Float(max(0, min(1, recipe.volume)))
        let overlay = loadOverlayCIImage(from: recipe.overlayURL, scaledTo: outputSize)

        // -- Drain video frames with speed-adjusted timestamps, rendering into
        //    portrait 1080×1920 output buffers --
        while let sample = videoOutput.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let srcTime = CMSampleBufferGetPresentationTimeStamp(sample)
            let relative = CMTimeSubtract(srcTime, trimStartTime)
            let outTime = speed == 1.0
                ? relative
                : CMTime(seconds: relative.seconds / speed, preferredTimescale: relative.timescale)

            try await awaitReady(videoInput, writer: writer)

            guard let outBuf = makeOutputBuffer(from: adaptor) else { continue }
            renderPortrait(source: pixelBuffer, into: outBuf, overlay: overlay)
            adaptor.append(outBuf, withPresentationTime: outTime)
        }
        videoInput.markAsFinished()

        // -- Drain audio (if any) with speed-adjusted timestamps + volume --
        if let audioOutput, let audioInput {
            while let sample = audioOutput.copyNextSampleBuffer() {
                let srcTime = CMSampleBufferGetPresentationTimeStamp(sample)
                let relative = CMTimeSubtract(srcTime, trimStartTime)
                let outTime = speed == 1.0
                    ? relative
                    : CMTime(seconds: relative.seconds / speed, preferredTimescale: relative.timescale)

                // Re-timestamp the sample buffer.
                if let retimed = retimedSample(sample, presentation: outTime, durationScaledBy: 1.0/speed) {
                    try await awaitReady(audioInput, writer: writer)
                    audioInput.append(retimed)
                }
                _ = volume  // applied after the fact would require AVAudioMix on an AVAssetExportSession; for the writer path we just pass through. Volume of 0 still mutes on the consumer side.
            }
            audioInput.markAsFinished()
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        guard writer.status == .completed else {
            throw VideoProcessorError.exportFailed(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
        return outputURL
    }

    /// Build a new CMSampleBuffer with a custom presentation timestamp and
    /// duration scale. Used for speed-changed audio (video uses adaptor.append).
    private static func retimedSample(_ sample: CMSampleBuffer,
                                      presentation: CMTime,
                                      durationScaledBy: Double) -> CMSampleBuffer? {
        var count = CMItemCount(0)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0,
                                                     arrayToFill: nil,
                                                     entriesNeededOut: &count) == 0,
              count > 0 else { return nil }
        var info = [CMSampleTimingInfo](repeating: .init(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count,
                                                     arrayToFill: &info,
                                                     entriesNeededOut: nil) == 0 else { return nil }
        for i in 0..<count {
            let dur = info[i].duration
            info[i].duration = CMTime(seconds: dur.seconds * durationScaledBy,
                                      preferredTimescale: dur.timescale)
            info[i].presentationTimeStamp = presentation
            info[i].decodeTimeStamp = .invalid
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                              sampleBuffer: sample,
                                              sampleTimingEntryCount: count,
                                              sampleTimingArray: info,
                                              sampleBufferOut: &out)
        return out
    }

    private static func export(composition: AVMutableComposition, audioMix: AVMutableAudioMix? = nil, suffix: String) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-\(suffix)-\(UUID().uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoProcessorError.exportFailed("Could not create exporter")
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.audioMix = audioMix

        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously { continuation.resume() }
        }

        switch exporter.status {
        case .completed: return outputURL
        case .failed:    throw VideoProcessorError.exportFailed(exporter.error?.localizedDescription ?? "unknown")
        case .cancelled: throw VideoProcessorError.exportFailed("cancelled")
        default:         throw VideoProcessorError.exportFailed("status \(exporter.status.rawValue)")
        }
    }

    // MARK: - Multi-region speed ramp + overlay compositing

    /// Runs the cinematic preset path: reads frames per ramp range, re-times
    /// each frame to the cumulative output time, center-crops into a 1080×1920
    /// portrait canvas, optionally composites a PNG overlay on every frame.
    private static func exportRamped(inputURL: URL, recipe: ProcessingRecipe) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw VideoProcessorError.noVideoTrack }

        let outputSize = renderSize
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-ramped-\(UUID().uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height)
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = .identity  // we render portrait pixels directly
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height)
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw VideoProcessorError.exportFailed("can't add video input")
        }
        writer.add(videoInput)

        guard writer.startWriting() else {
            throw VideoProcessorError.exportFailed(writer.error?.localizedDescription ?? "writer start")
        }
        writer.startSession(atSourceTime: .zero)

        let overlay = loadOverlayCIImage(from: recipe.overlayURL, scaledTo: outputSize)
        let scale: CMTimeScale = 600
        var cumulativeOutputTime: CMTime = .zero

        for ramp in recipe.speedRamps {
            let speed = max(0.01, ramp.multiplier)
            let rampStart = CMTime(seconds: ramp.from, preferredTimescale: scale)
            let rampDuration = max(0.001, ramp.to - ramp.from)
            let rampRange = CMTimeRange(
                start: rampStart,
                duration: CMTime(seconds: rampDuration, preferredTimescale: scale)
            )

            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = rampRange
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { continue }

            while let sample = output.copyNextSampleBuffer() {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let srcTime = CMSampleBufferGetPresentationTimeStamp(sample)
                let relative = CMTimeSubtract(srcTime, rampStart)
                let scaled = CMTime(seconds: relative.seconds / speed,
                                    preferredTimescale: relative.timescale)
                let outTime = CMTimeAdd(cumulativeOutputTime, scaled)

                try await awaitReady(videoInput, writer: writer)

                guard let outBuf = makeOutputBuffer(from: adaptor) else { continue }
                renderPortrait(source: pixelBuffer, into: outBuf, overlay: overlay)
                adaptor.append(outBuf, withPresentationTime: outTime)
            }

            cumulativeOutputTime = CMTimeAdd(
                cumulativeOutputTime,
                CMTime(seconds: rampDuration / speed, preferredTimescale: scale)
            )
        }

        videoInput.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        guard writer.status == .completed else {
            throw VideoProcessorError.exportFailed(writer.error?.localizedDescription
                ?? "ramped writer status \(writer.status.rawValue)")
        }
        return outputURL
    }

    // MARK: - Portrait rendering (1080×1920 output, GPU via CoreImage)

    /// Canonical portrait output size.
    /// Output canvas. Landscape 1920×1080 — the booth records and delivers
    /// horizontal video. `renderFrame` aspect-fills the source into this size, so
    /// a 16:9 source maps 1:1 with no crop.
    static let renderSize = CGSize(width: 1920, height: 1080)

    /// One CIContext shared across all frames. Cheap to render through, expensive
    /// to create. Use GPU when available (no software-renderer fallback).
    private static let ciContext: CIContext = {
        CIContext(options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            .outputColorSpace: CGColorSpaceCreateDeviceRGB()
        ])
    }()

    /// Loads an overlay PNG and pre-scales it to the output canvas size — one
    /// allocation, reused across every frame.
    private static func loadOverlayCIImage(from path: String?,
                                           scaledTo size: CGSize) -> CIImage? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        // UIImage handles PNG orientation metadata; convert to CIImage with
        // correct orientation, then scale to portrait canvas.
        guard let ui = UIImage(contentsOfFile: url.path),
              let cg = ui.cgImage else { return nil }
        let raw = CIImage(cgImage: cg)
        let extent = raw.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scaleX = size.width  / extent.width
        let scaleY = size.height / extent.height
        return raw.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }

    /// Render a source frame into the output pixel buffer with aspect-fill
    /// center crop, then composite the overlay. All GPU via CoreImage. For a 16:9
    /// source into the 16:9 landscape canvas this is a 1:1 map (no crop).
    private static func renderPortrait(source: CVPixelBuffer,
                                       into output: CVPixelBuffer,
                                       overlay: CIImage?) {
        let srcW = CGFloat(CVPixelBufferGetWidth(source))
        let srcH = CGFloat(CVPixelBufferGetHeight(source))
        let outW = CGFloat(CVPixelBufferGetWidth(output))
        let outH = CGFloat(CVPixelBufferGetHeight(output))

        // Zero-copy wrap.
        var srcImage = CIImage(cvPixelBuffer: source)

        // Aspect-fill: crop a region matching the output aspect, then scale.
        let srcAspect = srcW / srcH
        let outAspect = outW / outH
        let cropRect: CGRect
        if srcAspect > outAspect {
            let cropW = srcH * outAspect
            cropRect = CGRect(x: (srcW - cropW) / 2, y: 0, width: cropW, height: srcH)
        } else {
            let cropH = srcW / outAspect
            cropRect = CGRect(x: 0, y: (srcH - cropH) / 2, width: srcW, height: cropH)
        }

        srcImage = srcImage.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX,
                                                y: -cropRect.minY))
            .transformed(by: CGAffineTransform(scaleX: outW / cropRect.width,
                                               y: outH / cropRect.height))

        let final: CIImage = overlay.map { $0.composited(over: srcImage) } ?? srcImage

        ciContext.render(
            final,
            to: output,
            bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }

    /// Wait until the writer input can accept more data, but bail if the writer
    /// has FAILED — otherwise `isReadyForMoreMediaData` stays false forever and the
    /// export hangs (e.g. when the external camera and the encoder contend).
    private static func awaitReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        var waitedNs: UInt64 = 0
        let stallLimitNs: UInt64 = 12_000_000_000   // 12s with no progress = stalled
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw VideoProcessorError.exportFailed(writer.error?.localizedDescription ?? "writer failed mid-export")
            }
            if waitedNs >= stallLimitNs {
                throw VideoProcessorError.exportFailed("encoder stalled (no free hardware encoder)")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)   // 5ms
            waitedNs += 5_000_000
        }
    }

    /// Pull a fresh CVPixelBuffer from the adaptor's pool. Returns nil if the
    /// pool isn't available yet (rare, transient).
    private static func makeOutputBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    // MARK: - Reverse playback (frame-by-frame read/write)

    private static func exportReverse(inputURL: URL, recipe: ProcessingRecipe) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw VideoProcessorError.noVideoTrack }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-reverse-\(UUID().uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        // Read all sample buffers.
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw VideoProcessorError.exportFailed(reader.error?.localizedDescription ?? "reader")
        }

        var sampleTimes: [CMTime] = []
        var pixelBuffers: [CVPixelBuffer] = []
        while let sample = trackOutput.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sample) {
                pixelBuffers.append(pb)
                sampleTimes.append(CMSampleBufferGetPresentationTimeStamp(sample))
            }
        }
        guard !pixelBuffers.isEmpty else { throw VideoProcessorError.exportFailed("no frames") }

        // Build the writer.
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform   = try await videoTrack.load(.preferredTransform)

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: naturalSize.width,
            AVVideoHeightKey: naturalSize.height
        ])
        writerInput.transform = transform
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: naturalSize.width,
                kCVPixelBufferHeightKey as String: naturalSize.height
            ]
        )

        guard writer.canAdd(writerInput) else { throw VideoProcessorError.exportFailed("can't add writer input") }
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw VideoProcessorError.exportFailed(writer.error?.localizedDescription ?? "writer")
        }
        writer.startSession(atSourceTime: .zero)

        // Reverse-iterate, append frames with cumulative timestamps.
        let reversed = Array(pixelBuffers.reversed())
        let scale: CMTimeScale = sampleTimes.first?.timescale ?? 600
        let frameCount = reversed.count
        let totalDuration = sampleTimes.last ?? CMTime(seconds: Double(frameCount) / 30.0, preferredTimescale: scale)
        let perFrame = CMTime(value: totalDuration.value / max(1, Int64(frameCount)), timescale: totalDuration.timescale)

        // Inline append loop instead of requestMediaDataWhenReady — the callback
        // form takes a @Sendable closure and AVAssetWriterInput/PixelBufferAdaptor
        // aren't Sendable, so we'd otherwise need @unchecked Sendable boxes.
        var index = 0
        while index < reversed.count {
            try await awaitReady(writerInput, writer: writer)
            let t = CMTimeMultiply(perFrame, multiplier: Int32(index))
            let speedT: CMTime = recipe.speedMultiplier == 1.0
                ? t
                : CMTime(seconds: t.seconds / recipe.speedMultiplier, preferredTimescale: t.timescale)
            if !adaptor.append(reversed[index], withPresentationTime: speedT) {
                break
            }
            index += 1
        }
        writerInput.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }

        guard writer.status == .completed else {
            throw VideoProcessorError.exportFailed(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
        return outputURL
    }
}

// MARK: - Timeline export (multi-clip)

/// Builds the final delivered video from the timeline: each clip (the live app
/// recording and any imported clips, e.g. an end card) is processed individually
/// with its own per-clip recipe (trim / speed / speed-ramps / overlay), normalized
/// to landscape 1920×1080, then all are concatenated into one MP4.
enum TimelineExporter {
    static let importedClipsDirName = "TimelineClips"

    /// Directory where imported timeline clips live.
    static func clipsDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(importedClipsDirName, isDirectory: true)
    }

    static func export(recordingURL: URL) async throws -> URL {
        let clips = TimelineStore.loadClips()
        print("PivotBot 🎬 timeline export: \(clips.count) clip(s)")

        var processed: [URL] = []
        for (i, clip) in clips.enumerated() {
            print("PivotBot 🎬 clip \(i + 1)/\(clips.count) [\(clip.isRecording ? "recording" : "uploaded")] processing…")
            // Resolve the clip's source file.
            let src: URL
            if clip.isRecording {
                src = recordingURL
            } else if let name = clip.importedFilename {
                let url = clipsDir().appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                src = url
            } else {
                continue
            }

            let out: URL
            if clip.isRecording {
                // App-recorded segment: full per-clip recipe (trim/speed/reverse/…)
                // plus the auto Freedom 250 overlay (unless a custom one is set).
                var recipe = ProcessingRecipe.load(prefix: clip.recipeKeyPrefix)
                if (recipe.overlayURL ?? "").isEmpty, let p = bundledOverlayPath() {
                    recipe.overlayURL = p
                }
                out = try await VideoProcessor.process(inputURL: src, recipe: recipe, normalize: true)
            } else {
                // Uploaded clip: played as-is — no effects, no overlay — just
                // normalized to 1920×1080 so it concatenates cleanly.
                out = try await VideoProcessor.process(inputURL: src, recipe: ProcessingRecipe(), normalize: true)
            }
            processed.append(out)
            print("PivotBot 🎬 clip \(i + 1)/\(clips.count) done")
        }

        guard !processed.isEmpty else { throw VideoProcessorError.exportFailed("Timeline has no usable clips") }
        // Always run the finalize pass — even for a single clip — so the
        // delivered file is video-only. This booth ships silent (the camera mic
        // just captures arm/room noise nobody wants); concatenate() builds a
        // video-only composition, so it doubles as the guaranteed audio strip.
        print("PivotBot 🎬 finalizing \(processed.count) clip(s) — video only…")
        return try await concatenate(processed)
    }

    /// Sequentially splice the pre-normalized 1920×1080 clips into one MP4, and
    /// the booth's single delivery chokepoint — every capture passes through
    /// here even when there's only one clip.
    ///
    /// Video only: no audio track is ever added. The booth delivers silent clips
    /// (the camera mic just captures arm/room noise), and a video-only
    /// composition is also the simplest guaranteed way to strip audio. Building
    /// no audio track at all is safe — the old "Operation Stopped" (-16976) bug
    /// was specifically an EMPTY audio track, which we no longer create.
    /// Passthrough preset: every clip is already 1920×1080 H.264 from the
    /// per-clip pass, so stitching needs no re-encode.
    private static func concatenate(_ urls: [URL]) async throws -> URL {
        let composition = AVMutableComposition()
        guard let vTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoProcessorError.exportFailed("CONCAT — could not create composition track")
        }

        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                try vTrack.insertTimeRange(range, of: v, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-timeline-\(UUID().uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: outURL)

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoProcessorError.exportFailed("CONCAT — could not create timeline exporter")
        }
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        guard export.status == .completed else {
            throw VideoProcessorError.exportFailed("CONCAT — \(export.error?.localizedDescription ?? "status \(export.status.rawValue)")")
        }
        return outURL
    }

    /// Writes the bundled Freedom 250 overlay to a stable file once so the recipe
    /// (which loads overlays by file path) can composite it.
    static func bundledOverlayPath() -> String? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Overlays", isDirectory: true)
        let url = dir.appendingPathComponent("freedom250-overlay.png")
        if FileManager.default.fileExists(atPath: url.path) { return url.path }
        guard let img = UIImage(named: "Freedom250_Overlay"), let data = img.pngData() else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do { try data.write(to: url); return url.path } catch { return nil }
    }
}

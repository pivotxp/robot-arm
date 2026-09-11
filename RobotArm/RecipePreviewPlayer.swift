import SwiftUI
@preconcurrency import AVFoundation
import AVKit
import CoreImage

/// SwiftUI view that previews a clip with a ProcessingRecipe applied live.
/// Speed and volume drive the player directly. Trim, reverse, and looping are
/// enforced via a boundary time observer plus end-of-item notification.
struct RecipePreviewPlayer: View {
    let sourceURL: URL?
    let recipe: ProcessingRecipe

    @State private var player = AVPlayer()
    @State private var loadedURL: URL?
    @State private var assetSize: CGSize = CGSize(width: 1280, height: 720)
    @State private var assetDuration: CMTime = .zero
    @State private var assetTransform: CGAffineTransform = .identity
    @State private var assetVideoTrack: AVAssetTrack?

    @State private var boundaryToken: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var isReady = false

    var body: some View {
        ZStack {
            Color.black
            if let url = sourceURL {
                PlayerLayerView(player: player)
                    .onAppear { reload(url: url) }
                    .onChange(of: sourceURL) { _, new in if let n = new { reload(url: n) } }
                    .onChange(of: recipe) { _, _ in applyRecipe(seek: true) }
                    .onDisappear { teardownObservers() }
            } else {
                placeholder
            }
            overlayControls
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16/9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.white.opacity(0.5))
            Text("Preparing preview…")
                .font(.system(size: 13, weight: .heavy))
                .kerning(2)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var overlayControls: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Button {
                    applyRecipe(seek: true)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                Spacer()
                Text(recipeBadge)
                    .font(.system(size: 11, weight: .heavy))
                    .kerning(1.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
            }
            .padding(10)
        }
    }

    private var recipeBadge: String {
        var parts: [String] = []
        if recipe.speedMultiplier != 1.0 { parts.append(String(format: "%.3gx", recipe.speedMultiplier)) }
        if recipe.reverse { parts.append("REV") }
        if recipe.trimStart > 0 || recipe.trimEnd > 0 { parts.append("TRIM") }
        return parts.isEmpty ? "PLAY ONCE" : "LOOPING · " + parts.joined(separator: " · ")
    }

    // MARK: - Time helpers

    private var clipStart: CMTime {
        CMTime(seconds: max(0, recipe.trimStart), preferredTimescale: 600)
    }
    private var clipEnd: CMTime {
        if recipe.trimEnd > 0 {
            let bounded = min(recipe.trimEnd, assetDuration.seconds.isFinite ? assetDuration.seconds : recipe.trimEnd)
            return CMTime(seconds: bounded, preferredTimescale: 600)
        }
        return assetDuration
    }

    // MARK: - Loading

    private func reload(url: URL) {
        loadedURL = url
        let asset = AVURLAsset(url: url)
        Task {
            let duration   = (try? await asset.load(.duration)) ?? .zero
            let videoTrack = try? await asset.loadTracks(withMediaType: .video).first
            let size       = (try? await videoTrack?.load(.naturalSize)) ?? CGSize(width: 1280, height: 720)
            let transform  = (try? await videoTrack?.load(.preferredTransform)) ?? .identity

            await MainActor.run {
                assetDuration   = duration
                assetSize       = size
                assetTransform  = transform
                assetVideoTrack = videoTrack
            }

            let item = AVPlayerItem(asset: asset)
            await MainActor.run {
                teardownObservers()
                player.replaceCurrentItem(with: item)
                isReady = true
                installEndObserver()
                applyRecipe(seek: true)
            }
        }
    }

    private func teardownObservers() {
        if let t = boundaryToken { player.removeTimeObserver(t); boundaryToken = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
    }

    private func installEndObserver() {
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { _ in handleBoundary() }
    }

    private func installBoundaryObserver() {
        if let t = boundaryToken { player.removeTimeObserver(t); boundaryToken = nil }
        // For forward playback: fire at clipEnd (only when trim end set; otherwise
        // we let AVPlayerItemDidPlayToEndTime handle the natural end).
        // For reverse: fire at clipStart so we can loop or stop.
        if recipe.reverse {
            guard clipStart > .zero else { return }
            boundaryToken = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: clipStart)],
                queue: .main
            ) { handleBoundary() }
        } else if recipe.trimEnd > 0 {
            boundaryToken = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: clipEnd)],
                queue: .main
            ) { handleBoundary() }
        }
    }

    // MARK: - Recipe application

    private func applyRecipe(seek doSeek: Bool) {
        player.volume = Float(recipe.volume)
        player.actionAtItemEnd = .none

        if let item = player.currentItem {
            item.videoComposition = makeComposition(size: assetSize)
        }

        if doSeek {
            let start = recipe.reverse ? clipEnd : clipStart
            player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                playAtCurrentRate()
            }
        } else {
            playAtCurrentRate()
        }

        installBoundaryObserver()
    }

    private func playAtCurrentRate() {
        let absRate = max(0.01, Float(recipe.speedMultiplier))
        let signedRate = recipe.reverse ? -absRate : absRate
        player.rate = signedRate
    }

    private func handleBoundary() {
        if recipe.hasAnyEffect {
            // Loop back to start direction
            let restart = recipe.reverse ? clipEnd : clipStart
            player.seek(to: restart, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                playAtCurrentRate()
            }
        } else {
            // Default recipe: play once, then stop.
            player.pause()
            player.seek(to: clipEnd, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    // MARK: - Composition

    private func makeComposition(size: CGSize) -> AVVideoComposition? {
        guard assetDuration > .zero else { return nil }
        let composition = AVMutableVideoComposition()
        composition.renderSize = size
        composition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: assetDuration)

        if let videoTrack = assetVideoTrack {
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            let preferred = assetTransform
            let scaleX = recipe.sizeWidth / 100.0
            let scaleY = recipe.sizeHeight / 100.0
            let dx = (recipe.posX / 100.0) * size.width
            let dy = (recipe.posY / 100.0) * size.height
            var t = preferred
            t = t.concatenating(.init(translationX: -size.width/2, y: -size.height/2))
            t = t.rotated(by: CGFloat(recipe.rotation) * .pi / 180)
            t = t.scaledBy(x: CGFloat(scaleX), y: CGFloat(scaleY))
            t = t.concatenating(.init(translationX: size.width/2 + CGFloat(dx),
                                       y: size.height/2 + CGFloat(dy)))
            layer.setTransform(t, at: .zero)
            instruction.layerInstructions = [layer]
        }
        composition.instructions = [instruction]
        return composition
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PV {
        let v = PV()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ uiView: PV, context: Context) {
        uiView.playerLayer.player = player
    }
    final class PV: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: - Recipe helpers used by the player

extension ProcessingRecipe {
    var trimStartTime: CMTime {
        CMTime(seconds: max(0, trimStart), preferredTimescale: 600)
    }
}

// MARK: - Sample clip generator

enum PreviewSample {
    /// Returns the URL of the bundled preview-tester clip. Falls back to a
    /// programmatically generated sample if the bundled file is missing.
    static func defaultURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "preview-tester", withExtension: "mp4") {
            return bundled
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("preview-sample.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try generate(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Picks the most recent .mp4 in Documents/Captures, or falls back to the
    /// bundled/synthetic sample.
    static func bestAvailableURL() -> URL? {
        let captures = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: captures,
                                                                    includingPropertiesForKeys: [.creationDateKey]),
           let newest = files
            .filter({ $0.pathExtension.lowercased() == "mp4" })
            .max(by: {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a < b
            }) {
            return newest
        }
        return defaultURL()
    }

    /// Generates a small 5s 16:9 H.264 mp4 with an animated red disc on white.
    private static func generate(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)

        let size = CGSize(width: 640, height: 360)
        let fps: Int32 = 30
        let duration: TimeInterval = 5

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(duration) * Int(fps)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        for i in 0..<totalFrames {
            guard let pool = adaptor.pixelBufferPool,
                  let pb = makePixelBuffer(pool: pool) else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(pb),
                width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1))
                ctx.fill(CGRect(origin: .zero, size: size))

                let t = Double(i) / Double(totalFrames)
                let cx = 80 + CGFloat(t) * (size.width - 160)
                let cy = size.height / 2 + sin(CGFloat(t) * .pi * 2) * 60
                ctx.setFillColor(CGColor(red: 210/255, green: 10/255, blue: 10/255, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: cx - 40, y: cy - 40, width: 80, height: 80))

                let text = "PIVOTBOT" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 36, weight: .heavy),
                    .foregroundColor: UIColor(white: 0.12, alpha: 1)
                ]
                let textSize = text.size(withAttributes: attrs)
                UIGraphicsPushContext(ctx)
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
                text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: 24),
                          withAttributes: attrs)
                UIGraphicsPopContext()
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            let time = CMTime(value: CMTimeValue(i), timescale: fps)
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            adaptor.append(pb, withPresentationTime: time)
        }

        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "preview", code: 0)
        }
    }

    private static func makePixelBuffer(pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }
}

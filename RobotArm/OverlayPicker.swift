import SwiftUI
import PhotosUI
import UIKit

// MARK: - Overlay file manager

enum OverlayStorage {
    private static var dir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let d = docs.appendingPathComponent("Overlays", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func save(_ image: UIImage) -> URL? {
        let url = dir.appendingPathComponent("\(UUID().uuidString).png")
        guard let data = image.pngData() else { return nil }
        do {
            try data.write(to: url)
            return url
        } catch { return nil }
    }

    static func image(at urlString: String) -> UIImage? {
        guard !urlString.isEmpty else { return nil }
        // Saved paths are absolute file URLs.
        let url = URL(fileURLWithPath: urlString)
        return UIImage(contentsOfFile: url.path)
    }

    static func delete(_ urlString: String) {
        guard !urlString.isEmpty else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: urlString))
    }
}

// MARK: - Overlay column (drop-in replacement for the static placeholder)

struct OverlayColumn: View {
    @Binding var blendMode: String
    @Binding var overlayURL: String

    @State private var pickerItem: PhotosPickerItem?
    @State private var loadError: String?

    private let blendOptions = ["Normal", "Multiply", "Screen", "Overlay"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Blend Mode")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.ink)
                Spacer()
                Menu {
                    ForEach(blendOptions, id: \.self) { m in
                        Button(m) { blendMode = m }
                    }
                } label: {
                    HStack {
                        Text(blendMode)
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.ink)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Brand.inkMuted)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: 140)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.black.opacity(0.15), lineWidth: 1))
                }
            }

            // Picker / current overlay preview
            if overlayURL.isEmpty {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    VStack(spacing: 8) {
                        Image(systemName: "icloud.and.arrow.up")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(Brand.inkMuted.opacity(0.55))
                        Text("Tap to pick PNG")
                            .font(.system(size: 12, weight: .heavy))
                            .kerning(1)
                            .foregroundStyle(Brand.inkMuted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .background(
                        RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.96))
                    )
                }
            } else {
                overlayPreview
            }

            Text("Recommended: 1080×1920 PNG with transparent areas. Pick it from Photos — preview appears in the box above.")
                .font(.system(size: 11))
                .foregroundStyle(Brand.inkMuted)
            if let err = loadError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Brand.red)
            }
        }
        .onChange(of: pickerItem) { _, new in
            guard let new else { return }
            Task {
                do {
                    guard let data = try await new.loadTransferable(type: Data.self) else {
                        await MainActor.run { loadError = "No data returned by Photos." }
                        return
                    }
                    guard let img = UIImage(data: data) else {
                        await MainActor.run { loadError = "Couldn't decode image (\(data.count) bytes)." }
                        return
                    }
                    await MainActor.run {
                        // Delete previous overlay (if any) and save the new PNG directly.
                        if !overlayURL.isEmpty { OverlayStorage.delete(overlayURL) }
                        if let url = OverlayStorage.save(img) {
                            overlayURL = url.path
                            loadError = nil
                        } else {
                            loadError = "Save failed."
                        }
                        pickerItem = nil
                    }
                } catch {
                    await MainActor.run {
                        loadError = "Load error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private var overlayPreview: some View {
        VStack(spacing: 8) {
            if let img = OverlayStorage.image(at: overlayURL) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 140)
                    .background(
                        // Checker pattern so transparent PNGs are visible
                        ZStack {
                            Color.white
                            Image(systemName: "circle.grid.cross")
                                .resizable().scaledToFit()
                                .foregroundStyle(.black.opacity(0.05))
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Brand.ink)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color(white: 0.95)))
                }
                Button {
                    OverlayStorage.delete(overlayURL)
                    overlayURL = ""
                } label: {
                    Label("Remove", systemImage: "trash")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Brand.red))
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
    }
}

// MARK: - Cropper (freeform: draggable corners + draggable center)

struct OverlayCropperView: View {
    let image: UIImage
    var onComplete: (UIImage) -> Void
    var onCancel: () -> Void

    @State private var cropRect: CGRect = .zero
    @State private var imageBounds: CGRect = .zero
    @State private var dragStart: CGRect?

    private let minSize: CGFloat = 80
    private let handleSize: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                // Dim everything OUTSIDE the crop rect
                dimMask(in: geo.size)

                // Crop frame border + handles
                cropFrame

                topBar
            }
            .onAppear {
                computeBounds(container: geo.size)
                cropRect = imageBounds
            }
        }
    }

    private func dimMask(in containerSize: CGSize) -> some View {
        Color.black.opacity(0.55)
            .ignoresSafeArea()
            .mask(
                ZStack {
                    Rectangle()
                    Rectangle()
                        .frame(width: max(0, cropRect.width), height: max(0, cropRect.height))
                        .position(x: cropRect.midX, y: cropRect.midY)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            )
            .allowsHitTesting(false)
    }

    private var cropFrame: some View {
        ZStack {
            // Border + thirds grid
            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
            ForEach(1..<3) { i in
                Path { p in
                    let x = cropRect.minX + cropRect.width / 3 * CGFloat(i)
                    p.move(to: CGPoint(x: x, y: cropRect.minY))
                    p.addLine(to: CGPoint(x: x, y: cropRect.maxY))
                }.stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                Path { p in
                    let y = cropRect.minY + cropRect.height / 3 * CGFloat(i)
                    p.move(to: CGPoint(x: cropRect.minX, y: y))
                    p.addLine(to: CGPoint(x: cropRect.maxX, y: y))
                }.stroke(Color.white.opacity(0.4), lineWidth: 0.5)
            }

            // Center drag
            Color.clear
                .contentShape(Rectangle())
                .frame(width: max(0, cropRect.width - handleSize),
                       height: max(0, cropRect.height - handleSize))
                .position(x: cropRect.midX, y: cropRect.midY)
                .gesture(moveGesture)

            // Corner handles
            handle(at: CGPoint(x: cropRect.minX, y: cropRect.minY), corner: .topLeft)
            handle(at: CGPoint(x: cropRect.maxX, y: cropRect.minY), corner: .topRight)
            handle(at: CGPoint(x: cropRect.minX, y: cropRect.maxY), corner: .bottomLeft)
            handle(at: CGPoint(x: cropRect.maxX, y: cropRect.maxY), corner: .bottomRight)
        }
    }

    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    private func handle(at pos: CGPoint, corner: Corner) -> some View {
        Circle()
            .strokeBorder(Color.white, lineWidth: 3)
            .background(Circle().fill(Color.black.opacity(0.5)))
            .frame(width: handleSize, height: handleSize)
            .position(pos)
            .gesture(cornerGesture(corner))
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = cropRect }
                guard let s = dragStart else { return }
                var new = s.offsetBy(dx: value.translation.width, dy: value.translation.height)
                // Clamp to imageBounds
                if new.minX < imageBounds.minX { new.origin.x = imageBounds.minX }
                if new.minY < imageBounds.minY { new.origin.y = imageBounds.minY }
                if new.maxX > imageBounds.maxX { new.origin.x = imageBounds.maxX - new.width }
                if new.maxY > imageBounds.maxY { new.origin.y = imageBounds.maxY - new.height }
                cropRect = new
            }
            .onEnded { _ in dragStart = nil }
    }

    private func cornerGesture(_ corner: Corner) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = cropRect }
                guard let s = dragStart else { return }
                var new = s
                let dx = value.translation.width
                let dy = value.translation.height
                switch corner {
                case .topLeft:
                    new.origin.x = s.minX + dx
                    new.origin.y = s.minY + dy
                    new.size.width  = s.width - dx
                    new.size.height = s.height - dy
                case .topRight:
                    new.origin.y = s.minY + dy
                    new.size.width  = s.width + dx
                    new.size.height = s.height - dy
                case .bottomLeft:
                    new.origin.x = s.minX + dx
                    new.size.width  = s.width - dx
                    new.size.height = s.height + dy
                case .bottomRight:
                    new.size.width  = s.width + dx
                    new.size.height = s.height + dy
                }
                // Min size — pin the opposite edge
                if new.size.width < minSize {
                    if corner == .topLeft || corner == .bottomLeft {
                        new.origin.x = s.maxX - minSize
                    }
                    new.size.width = minSize
                }
                if new.size.height < minSize {
                    if corner == .topLeft || corner == .topRight {
                        new.origin.y = s.maxY - minSize
                    }
                    new.size.height = minSize
                }
                // Clamp to image bounds
                if new.minX < imageBounds.minX {
                    new.size.width += new.minX - imageBounds.minX
                    new.origin.x = imageBounds.minX
                }
                if new.minY < imageBounds.minY {
                    new.size.height += new.minY - imageBounds.minY
                    new.origin.y = imageBounds.minY
                }
                if new.maxX > imageBounds.maxX { new.size.width = imageBounds.maxX - new.origin.x }
                if new.maxY > imageBounds.maxY { new.size.height = imageBounds.maxY - new.origin.y }
                cropRect = new
            }
            .onEnded { _ in dragStart = nil }
    }

    private var topBar: some View {
        VStack {
            HStack {
                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                }
                Spacer()
                Text("CROP PNG")
                    .font(.system(size: 14, weight: .heavy)).kerning(3)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    if let cropped = renderCrop() {
                        onComplete(cropped)
                    } else {
                        onCancel()
                    }
                } label: {
                    Text("Apply")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Capsule().fill(Brand.red))
                }
            }
            .padding()
            Spacer()
        }
    }

    private func computeBounds(container: CGSize) {
        let aspect = image.size.width / image.size.height
        let cAspect = container.width / container.height
        let fit: CGSize
        if aspect > cAspect {
            fit = CGSize(width: container.width, height: container.width / aspect)
        } else {
            fit = CGSize(width: container.height * aspect, height: container.height)
        }
        let origin = CGPoint(
            x: (container.width - fit.width) / 2,
            y: (container.height - fit.height) / 2
        )
        imageBounds = CGRect(origin: origin, size: fit)
    }

    private func renderCrop() -> UIImage? {
        guard imageBounds.width > 0, imageBounds.height > 0 else { return nil }
        let scaleX = image.size.width / imageBounds.width
        let scaleY = image.size.height / imageBounds.height
        let rect = CGRect(
            x: max(0, (cropRect.origin.x - imageBounds.origin.x) * scaleX),
            y: max(0, (cropRect.origin.y - imageBounds.origin.y) * scaleY),
            width: cropRect.width * scaleX,
            height: cropRect.height * scaleY
        ).integral
        guard rect.width >= 1, rect.height >= 1,
              let cg = image.cgImage?.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }
}

import AVKit
import Photos
import SwiftUI

/// The booth screen: the camera, one CAPTURE button, and what is happening. Clean enough for a
/// demo, plain enough to take branding later.
///
/// Getting out: three taps on the top-left corner — each tap lights a dot so the crew can see
/// it counting — then the crew PIN opens the admin screen. With Support mode on there is a
/// plain "Support" button instead. STOP is always there, because the rig moves.
struct BoothView: View {
    @ObservedObject private var booth = Booth.shared
    @ObservedObject private var flow = CaptureFlow.shared
    @ObservedObject private var recorder = Recorder.shared
    @ObservedObject private var runner = Runner.shared
    @ObservedObject private var store = ProgramStore.shared
    @ObservedObject private var arm = ArmLink.shared
    @ObservedObject private var rail = RailLink.shared

    @State private var cornerTaps = 0
    @State private var cornerReset: Task<Void, Never>?
    @State private var showPIN = false
    @State private var player: AVPlayer?
    @State private var autoReset: Task<Void, Never>?
    @State private var pulse = false

    var body: some View {
        ZStack {
            camera
            // Soft shading top and bottom so text and buttons read over any scene.
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                   .init(color: .clear, location: 0.22),
                                   .init(color: .clear, location: 0.68),
                                   .init(color: .black.opacity(0.6), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                top
                Spacer()
                centre
                Spacer()
                bottom
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
        }
        .background(Color.black)
        .statusBarHidden(true)
        .task {
            await Recorder.prepareAuthorization()
            if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
                _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            }
            await recorder.start()
        }
        .onDisappear { recorder.stop() }
        .onChange(of: flow.phase) { _, p in
            if case .done(let url) = p {
                let pl = AVPlayer(url: url)
                pl.play()
                player = pl
                autoReset?.cancel()
                autoReset = Task {
                    try? await Task.sleep(nanoseconds: 14_000_000_000)
                    if !Task.isCancelled { next() }
                }
            } else {
                player = nil
            }
        }
        .sheet(isPresented: $showPIN) {
            PINPad { entered in
                if booth.tryUnlock(entered) { showPIN = false; return true }
                return false
            }
        }
    }

    // MARK: Layers

    @ViewBuilder
    private var camera: some View {
        if case .done = flow.phase, let player {
            VideoPlayer(player: player)
                .ignoresSafeArea()
        } else if recorder.isRunning {
            CameraPreview(session: recorder.session)
                .ignoresSafeArea()
        } else {
            VStack(spacing: 12) {
                Image(systemName: "video.slash").font(.system(size: 44))
                Text(recorder.status).font(.title3)
            }
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    /// Left: the tap counter (or the Support button). Middle: the wordmark. Right: crew lights.
    private var top: some View {
        ZStack {
            HStack(alignment: .top) {
                if booth.supportMode {
                    Button {
                        booth.locked = false
                    } label: {
                        Label("Support", systemImage: "wrench.and.screwdriver")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(.ultraThinMaterial, in: Capsule())
                } else {
                    HStack(spacing: 9) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(i < cornerTaps ? Color.white : Color.white.opacity(0.28))
                                .frame(width: 11, height: 11)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .opacity(cornerTaps > 0 ? 1 : 0)
                    .frame(width: 170, height: 100, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { cornerTap() }
                    .animation(.easeOut(duration: 0.15), value: cornerTaps)
                }

                Spacer()

                if booth.supportMode {
                    HStack(spacing: 12) {
                        light(arm.connected, "Arm")
                        light(rail.connected, "Rail")
                        Text(programName)
                        if recorder.isRunning { Text(recorder.status) }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }

            // Branding goes here. A plain wordmark until it does.
            Text("PIVOT")
                .font(Brand.condensedBlack(size: 30))
                .tracking(6)
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var centre: some View {
        switch flow.phase {
        case .countdown(let n):
            Text("\(n)")
                .font(.system(size: 280, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .shadow(color: .black.opacity(0.5), radius: 30)
                .id(n)
                .transition(.scale(scale: 1.3).combined(with: .opacity))
        case .armed:
            Text("Get ready…")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 16)
        case .recording:
            HStack(spacing: 12) {
                Circle()
                    .fill(Brand.redHi)
                    .frame(width: 16, height: 16)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .onDisappear { pulse = false }
                Text("Recording")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .frame(maxHeight: .infinity, alignment: .top)
        case .rendering:
            VStack(spacing: 18) {
                ProgressView().controlSize(.large).tint(.white)
                Text("Building your clip…")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 40).padding(.vertical, 32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        case .failed(let why):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40))
                Text(why)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 40).padding(.vertical, 30)
            .frame(maxWidth: 640)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        case .idle, .done:
            EmptyView()
        }
    }

    /// STOP on the left, the one big button in the middle, a matching blank on the right so the
    /// button stays centred.
    @ViewBuilder
    private var bottom: some View {
        HStack(alignment: .bottom) {
            Button {
                flow.stop()
            } label: {
                Text("STOP")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 104, height: 50)
                    .background(Brand.red, in: Capsule())
            }
            .buttonStyle(PressStyle())
            .opacity(flow.phase.isBusy || runner.running ? 1 : 0.35)

            Spacer()

            switch flow.phase {
            case .idle:
                VStack(spacing: 14) {
                    if let b = flow.blocker {
                        Label(b, systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    } else {
                        Text("Step in, then tap")
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Button {
                        Haptics.heavy()
                        flow.capture()
                    } label: {
                        Label("CAPTURE", systemImage: "camera.fill")
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .foregroundStyle(.black)
                            .frame(width: 380, height: 96)
                            .background(
                                LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.78)],
                                               startPoint: .top, endPoint: .bottom),
                                in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                            .shadow(color: Color.accentColor.opacity(0.45), radius: 22, y: 8)
                    }
                    .buttonStyle(PressStyle())
                    .disabled(flow.blocker != nil)
                    .opacity(flow.blocker == nil ? 1 : 0.45)
                }
            case .done, .failed:
                VStack(spacing: 12) {
                    if case .done = flow.phase {
                        Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    if let n = flow.note {
                        Text(n).font(.caption).foregroundStyle(.orange)
                    }
                    Button {
                        next()
                    } label: {
                        Text("NEXT")
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .foregroundStyle(.black)
                            .frame(width: 280, height: 74)
                            .background(Color.accentColor, in: Capsule())
                            .shadow(color: Color.accentColor.opacity(0.4), radius: 18, y: 6)
                    }
                    .buttonStyle(PressStyle())
                }
            default:
                Text(runner.status)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()
            Color.clear.frame(width: 104, height: 50)
        }
    }

    private func light(_ on: Bool, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(on ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(label)
        }
    }

    // MARK: Logic

    private var programName: String {
        guard let n = booth.program else { return "No program chosen" }
        return store.program(n)?.name ?? "Program \(n)"
    }

    private func next() {
        autoReset?.cancel()
        player?.pause()
        player = nil
        flow.reset()
    }

    /// Three taps within three seconds of each other. The dots show the count.
    private func cornerTap() {
        Haptics.light()
        cornerTaps += 1
        cornerReset?.cancel()
        if cornerTaps >= 3 {
            showPIN = true
            cornerReset = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                cornerTaps = 0
            }
            return
        }
        cornerReset = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { cornerTaps = 0 }
        }
    }
}

/// Shrinks a little while pressed, so a big button feels like one.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Four-digit entry. Returns true from `submit` when the PIN was right.
struct PINPad: View {
    let submit: (String) -> Bool
    @State private var entered = ""
    @State private var wrong = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Text("Crew PIN").font(.title2.bold())
            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .strokeBorder(.primary, lineWidth: 1.5)
                        .background(Circle().fill(i < entered.count ? Color.primary : Color.clear))
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.bottom, 6)
            if wrong { Text("Wrong PIN").foregroundStyle(.red).font(.subheadline) }
            let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 18) {
                    ForEach(row, id: \.self) { key in
                        Button {
                            press(key)
                        } label: {
                            Text(key)
                                .font(.system(size: 30, weight: .medium))
                                .frame(width: 76, height: 76)
                        }
                        .buttonStyle(.bordered)
                        .opacity(key.isEmpty ? 0 : 1)
                        .disabled(key.isEmpty)
                    }
                }
            }
            Button("Cancel") { dismiss() }
                .padding(.top, 8)
        }
        .padding(36)
        .presentationDetents([.medium, .large])
    }

    private func press(_ key: String) {
        Haptics.light()
        if key == "⌫" { _ = entered.popLast(); return }
        guard entered.count < 4 else { return }
        entered += key
        if entered.count == 4 {
            if submit(entered) {
                dismiss()
            } else {
                wrong = true
                Haptics.error()
                entered = ""
            }
        }
    }
}

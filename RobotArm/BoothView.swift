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

    var body: some View {
        ZStack {
            camera
            VStack(spacing: 0) {
                top
                Spacer()
                centre
                Spacer()
                bottom
            }
            .padding(28)
        }
        .background(Color.black)
        .statusBarHidden(true)
        .task {
            // Both permissions now, while the crew is at the iPad — not mid-capture in front of a
            // guest, where the system dialog would cover the screen at the worst moment.
            await Recorder.prepareAuthorization()
            if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
                _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            }
            await recorder.start()
        }
        .onDisappear { recorder.stop() }
        .onChange(of: flow.phase) { _, p in
            // A finished clip plays for a while, then the screen resets for the next guest.
            if case .done(let url) = p {
                let pl = AVPlayer(url: url)
                pl.play()
                player = pl
                autoReset?.cancel()
                autoReset = Task {
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
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

    /// Top-left: the tap counter (or the Support button). Top-right: what this booth runs.
    private var top: some View {
        HStack(alignment: .top) {
            if booth.supportMode {
                Button {
                    booth.locked = false
                } label: {
                    Label("Support", systemImage: "wrench.and.screwdriver")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            } else {
                // Unmarked until the first tap; then three dots count the taps.
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(i < cornerTaps ? Color.white : Color.white.opacity(0.25))
                            .frame(width: 12, height: 12)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(.black.opacity(0.35), in: Capsule())
                .opacity(cornerTaps > 0 ? 1 : 0)
                .frame(width: 150, height: 90, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { cornerTap() }
                .animation(.easeOut(duration: 0.15), value: cornerTaps)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(programName)
                    .font(.headline)
                if booth.supportMode {
                    HStack(spacing: 10) {
                        light(arm.connected, "Arm")
                        light(rail.connected, "Rail")
                        if recorder.isRunning { Text(recorder.status) }
                    }
                    .font(.caption)
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var centre: some View {
        switch flow.phase {
        case .countdown(let n):
            Text("\(n)")
                .font(.system(size: 240, weight: .black))
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .shadow(radius: 24)
        case .armed:
            Text("Get ready…")
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(.white)
                .shadow(radius: 12)
        case .recording:
            Label("Recording", systemImage: "record.circle.fill")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 28).padding(.vertical, 14)
                .background(Brand.red, in: Capsule())
        case .rendering:
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(.white)
                Text("Building your clip…")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            .padding(30)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
        case .failed(let why):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44))
                Text(why).font(.title3).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(30)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
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
                    .font(.system(size: 20, weight: .black))
                    .frame(width: 110, height: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .opacity(flow.phase.isBusy || runner.running ? 1 : 0.4)

            Spacer()

            switch flow.phase {
            case .idle:
                VStack(spacing: 10) {
                    if let b = flow.blocker {
                        Text(b)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.black.opacity(0.55), in: Capsule())
                    }
                    Button {
                        Haptics.heavy()
                        flow.capture()
                    } label: {
                        Label("CAPTURE", systemImage: "camera.fill")
                            .font(.system(size: 36, weight: .black))
                            .frame(width: 360, height: 96)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(flow.blocker != nil)
                }
            case .done, .failed:
                VStack(spacing: 10) {
                    if case .done = flow.phase {
                        Text("Saved to Photos").font(.headline).foregroundStyle(.white)
                    }
                    if let n = flow.note {
                        Text(n).font(.caption).foregroundStyle(.orange)
                    }
                    Button {
                        next()
                    } label: {
                        Text("NEXT")
                            .font(.system(size: 28, weight: .black))
                            .frame(width: 260, height: 72)
                    }
                    .buttonStyle(.borderedProminent)
                }
            default:
                Text(runner.status)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.black.opacity(0.45), in: Capsule())
            }

            Spacer()
            Color.clear.frame(width: 110, height: 52)
        }
    }

    private func light(_ on: Bool, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(on ? Color.green : Color.red).frame(width: 9, height: 9)
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

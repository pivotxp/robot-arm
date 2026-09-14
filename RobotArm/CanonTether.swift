import Foundation
import ImageCaptureCore
import SwiftUI
import UIKit
@preconcurrency import AVFoundation

// MARK: - Errors

enum CanonTetherError: Error, LocalizedError {
    case notConnected
    case notRecording
    case alreadyRecording
    case ptp(op: String, code: UInt16)
    case timeout(String)
    case transfer(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:      return "Canon R8 not connected"
        case .notRecording:      return "Camera is not recording"
        case .alreadyRecording:  return "Camera is already recording"
        case .ptp(let op, let code):
            return "\(op) failed — \(Self.describe(code))"
        case .timeout(let what): return "Timed out waiting for \(what)"
        case .transfer(let m):   return "Transfer failed — \(m)"
        }
    }

    /// Friendly names for the PTP response codes operators actually hit.
    static func describe(_ code: UInt16) -> String {
        switch code {
        case 0x2001: return "OK"
        case 0x2019: return "camera busy"
        case 0x200C: return "memory card full"
        case 0x2013: return "memory card not available"
        case 0x201D: return "invalid parameter"
        case 0xA081: return "camera not ready (check Movie mode + HFR)"
        default:     return String(format: "PTP error 0x%04X", code)
        }
    }
}

// MARK: - Canon EOS PTP constants
//
// Canon's EOS vendor extension to PTP, as documented by the libgphoto2
// project (camlibs/ptp2/ptp.h) and used by every open-source EOS tether tool.

private enum EOS {
    // Operations
    static let getStorageIDs: UInt16        = 0x9101
    static let deleteObject: UInt16         = 0x9105  // (handle) — remove file from card
    static let getPartialObject: UInt16     = 0x9107  // (handle, offset, size) → data
    /// Shutter. Press = (0x3 = AF + full press, 0); release = (0x3). Ported from PivotBooth's
    /// still booth, where the earlier bug was releasing with 0x912A (RegistBackgroundImage) —
    /// the press never let go and the next shot sat in Device-Busy for ~5 s.
    static let remoteReleaseOn: UInt16      = 0x9128
    static let remoteReleaseOff: UInt16     = 0x9129
    static let setDevicePropValueEx: UInt16 = 0x9110  // data: [u32 len][u32 prop][value]
    static let setRemoteMode: UInt16        = 0x9114  // (1) = PC-remote handshake
    static let setEventMode: UInt16         = 0x9115  // (1) = enable event reporting
    static let getEvent: UInt16             = 0x9116  // () → packed change records
    static let transferComplete: UInt16     = 0x9117  // (handle) after full download
    static let pcHDDCapacity: UInt16        = 0x911A  // advertise host free space
    static let keepDeviceOn: UInt16         = 0x911D  // ping to defeat auto power-off
    static let getViewFinderData: UInt16    = 0x9153  // (flags) → packed EVF frame blob

    // Device properties (via setDevicePropValueEx). Values confirmed against
    // libgphoto2 camlibs/ptp2/ptp.h (Canon EOS extension).
    /// PTP_DPC_CANON_EOS_EVFRecordStatus: 4 = start movie record to card,
    /// 0 = stop. The camera must be in Movie mode (dial) AND have Live View
    /// active for 4 to take — EOS won't start recording without LV running.
    static let propMovieRecord: UInt32 = 0xD1B8
    /// PTP_DPC_CANON_EOS_EVFOutputDevice. Set to `evfOutputPC` to push EVF
    /// frames to the host over USB; 0 turns Live View off.
    static let propEVFOutputDevice: UInt32 = 0xD1B0
    /// PTP_DPC_CANON_EOS_EVFMode: 1 = Live View on.
    static let propEVFMode: UInt32         = 0xD1B1

    /// EVFOutputDevice value that routes Live View to the connected computer.
    static let evfOutputPC: UInt32 = 2
    /// GetViewFinderData flag EOS Utility uses to pull one Live View frame.
    static let viewFinderFlag: UInt32 = 0x00100000

    // GetEvent record types
    static let evtObjectAddedEx: UInt32   = 0xC181  // new file on card (32-bit size)
    static let evtObjectAddedEx64: UInt32 = 0xC1A7  // new file on card (64-bit size)
    static let evtPropValueChanged: UInt32 = 0xC189

    // PTP response codes
    static let respOK: UInt16 = 0x2001
    static let respDeviceBusy: UInt16 = 0x2019
}

/// A new-object record parsed out of a GetEvent blob.
private struct NewObject {
    let handle: UInt32
    let storageID: UInt32
    let formatCode: UInt32
    let size: UInt64        // 0 when the camera didn't report it
    let filename: String
}

// MARK: - Controller

/// Tethered-capture controller for the Canon R8: discovers the camera over the
/// iPad's USB-C port via ImageCaptureCore, drives in-camera movie recording
/// with Canon EOS vendor PTP commands, and downloads the recorded clip off the
/// card when the take ends, and streams the EVF live view back over the same
/// USB cable for the on-screen guest preview.
@MainActor
final class CanonTetherController: NSObject, ObservableObject {
    enum Status: Equatable {
        case disabled                 // browser stopped (teardown / mid-recovery)
        case searching                // browsing for a USB camera
        case connecting(name: String) // session opening / handshake running
        case ready(name: String)      // handshake done, idle
        case failed(String)
    }

    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case stopping
        case transferring
    }

    @Published private(set) var status: Status = .disabled
    @Published private(set) var phase: Phase = .idle
    /// Wall-clock delay between sending the record command and the camera
    /// confirming it, from the last take. Shown in Settings so the operator can
    /// dial the recording offset (robobooth.preRollSeconds) to absorb it.
    @Published private(set) var lastStartLatencyMs: Int?
    /// Most recent decoded Live View frame from the EVF stream. The capture
    /// screen renders this as the guest preview in Canon mode. nil before the
    /// first frame arrives and whenever Live View is off.
    @Published private(set) var previewImage: UIImage?
    /// True once the EVF push loop is running (a preview is expected shortly).
    @Published private(set) var liveViewRunning = false

    var isReadyToRecord: Bool {
        if case .ready = status { return phase == .idle }
        return false
    }

    var statusLabel: String {
        switch status {
        case .disabled:             return "off"
        case .searching:            return "searching for camera…"
        case .connecting(let n):    return "connecting to \(n)…"
        case .failed(let m):        return "failed — \(m)"
        case .ready(let n):
            switch phase {
            case .idle:         return "\(n) ready"
            case .starting:     return "\(n) starting…"
            case .recording:    return "\(n) recording"
            case .stopping:     return "\(n) finishing take…"
            case .transferring: return "\(n) downloading clip…"
            }
        }
    }

    private var browser: ICDeviceBrowser?
    private var camera: ICCameraDevice?
    private var cameraName: String = "Canon"
    private var eventLoopTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var liveViewTask: Task<Void, Never>?
    /// Counts the first several Live View pulls so we can log their raw PTP
    /// response codes / byte counts without spamming once frames flow.
    private var liveViewDiag = 0
    /// When true the EVF pull loop idles (e.g. while the QR scanner owns the
    /// camera stack) without tearing Live View down.
    private var liveViewPaused = false
    /// Debounce flag so a flapping connection doesn't launch many recoveries.
    private var recovering = false
    /// Guards against the handshake running twice (didOpenSession +
    /// deviceDidBecomeReady both fire on connect).
    private var handshaking = false
    /// Start time of the current connect attempt, for the timing breakdown logs.
    private var connectClock: Date?

    /// Milliseconds since the current connect attempt began (for stage timing).
    private func elapsed() -> Int {
        Int((Date().timeIntervalSince(connectClock ?? Date())) * 1000)
    }
    /// One-at-a-time gate for PTP traffic. The event loop, keep-alive ping,
    /// Live View pull, and chunked download all share the single ImageCaptureCore
    /// command channel; serializing keeps their transactions from interleaving.
    private let ptpGate = AsyncSemaphore(1)

    /// New-object events seen since recording started; the stop path consumes
    /// the first one that looks like a movie.
    private var pendingObjects: [NewObject] = []
    private var recordStartedAt: Date?

    // MARK: Lifecycle

    func start() {
        guard browser == nil else { return }
        connectClock = Date()
        print("RobotArm 🎥 Canon: browser start")
        status = .searching
        let b = ICDeviceBrowser()
        b.delegate = self
        b.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        ) ?? .camera
        browser = b
        // We only need "control" authorization — that's what gates sending PTP
        // commands (our record triggers, Live View pulls, and the by-handle
        // GetPartialObject download). We deliberately do NOT request "contents"
        // authorization: it makes ImageCaptureCore enumerate the entire card's
        // file catalog before the device is ready, which is the slow part of
        // connecting. We never touch ICCameraItem files, so we skip it.
        b.requestControlAuthorization { [weak self] control in
            Task { @MainActor in
                guard let self, self.browser === b else { return }
                guard control == .authorized else {
                    self.status = .failed("camera control denied — allow in iOS Settings → Privacy")
                    return
                }
                print("RobotArm 🎥 Canon: control auth ok (+\(self.elapsed())ms) — browsing")
                b.start()
            }
        }
    }

    func stop() {
        stopLiveView()
        eventLoopTask?.cancel(); eventLoopTask = nil
        keepAliveTask?.cancel(); keepAliveTask = nil
        if let cam = camera {
            cam.requestCloseSession()
        }
        camera = nil
        browser?.stop()
        browser = nil
        phase = .idle
        handshaking = false
        status = .disabled
    }

    /// Common cleanup when the camera goes away on its own (unplugged, session
    /// closed by the system). Drops the camera FIRST so the cancelled loops
    /// can't try to talk to a device that's no longer there, then clears the
    /// preview and parks the status.
    private func teardownConnection(reconnecting: Bool) {
        camera = nil
        liveViewTask?.cancel(); liveViewTask = nil
        eventLoopTask?.cancel(); eventLoopTask = nil
        keepAliveTask?.cancel(); keepAliveTask = nil
        liveViewRunning = false
        previewImage = nil
        pendingObjects.removeAll()
        phase = .idle
        handshaking = false
        status = reconnecting ? .searching : .disabled
    }

    // MARK: - Recording control

    /// Start in-camera movie recording. Completion fires once the camera has
    /// accepted the record command (or definitively failed). Retries through
    /// transient "device busy" responses, which the camera returns while it's
    /// still finalizing a previous clip.
    func startRecording(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let cam = camera, case .ready = status else {
            completion(.failure(CanonTetherError.notConnected)); return
        }
        guard phase == .idle else {
            completion(.failure(CanonTetherError.alreadyRecording)); return
        }
        phase = .starting
        pendingObjects.removeAll()
        let t0 = Date()
        Task { @MainActor in
            do {
                try await setMovieRecord(cam, on: true)
                self.lastStartLatencyMs = Int(Date().timeIntervalSince(t0) * 1000)
                self.recordStartedAt = Date()
                self.phase = .recording
                print("RobotArm 🎥 Canon record START ok (\(self.lastStartLatencyMs ?? 0) ms)")
                completion(.success(()))
            } catch {
                self.phase = .idle
                print("RobotArm ⚠️ Canon record START failed — \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    /// Stop recording, wait for the camera to register the finished clip, pull
    /// it off the card, normalize HFR timing, and move it to `destination`.
    func stopRecordingAndFetch(
        to destination: URL,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let cam = camera else {
            completion(.failure(CanonTetherError.notConnected)); return
        }
        guard phase == .recording || phase == .starting else {
            completion(.failure(CanonTetherError.notRecording)); return
        }
        phase = .stopping
        let wallClock = recordStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        Task { @MainActor in
            do {
                try await setMovieRecord(cam, on: false)
                print("RobotArm 🎥 Canon record STOP ok (\(String(format: "%.2f", wallClock))s wall clock)")

                // The camera finalizes the clip and then announces it via the
                // event stream. HFR takes can need a few seconds to finalize.
                let object = try await waitForNewMovieObject(cam, timeout: 20)
                print("RobotArm 🎥 Canon new object 0x\(String(object.handle, radix: 16)) \(object.filename) (\(object.size / 1_048_576) MB)")

                self.phase = .transferring
                let raw = try await download(object, from: cam, progress: progress)

                // 180fps HFR clips may be conformed in-camera (written as
                // 29.97p slow motion). Retime to real time so the timeline's
                // speed math treats tethered files exactly like UVC ones.
                let normalized = try await CanonClipNormalizer.retimeIfConformed(
                    url: raw, wallClockSeconds: wallClock)

                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: normalized, to: destination)
                self.phase = .idle
                // Delete the clip off the card now that it's safely on the iPad.
                // Keeps the card near-empty so ImageCaptureCore re-enumeration on
                // every (re)connect stays fast through a long event. Best-effort
                // — the take is already delivered if this fails.
                await self.deleteCardObject(object.handle, from: cam)
                completion(.success(destination))
            } catch {
                self.phase = .idle
                print("RobotArm ⚠️ Canon stop/fetch failed — \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    /// Abort a take: stop the camera if it's rolling and discard whatever it
    /// recorded (the partial clip stays on the card; nothing is downloaded).
    func cancelRecording(completion: @escaping () -> Void) {
        guard let cam = camera, phase == .recording || phase == .starting else {
            phase = .idle
            completion(); return
        }
        phase = .stopping
        Task { @MainActor in
            try? await setMovieRecord(cam, on: false)
            self.pendingObjects.removeAll()
            self.phase = .idle
            completion()
        }
    }

    // MARK: - EOS protocol: record property

    /// Movie record start/stop = SetDevicePropValueEx(propMovieRecord, 4|0).
    /// Retries through DeviceBusy — the camera reports busy while writing out
    /// the previous clip or autofocusing.
    private func setMovieRecord(_ cam: ICCameraDevice, on: Bool) async throws {
        var payload = Data()
        payload.appendU32(12)                       // total length of this block
        payload.appendU32(EOS.propMovieRecord)
        payload.appendU32(on ? 4 : 0)               // 4 = record to card, 0 = stop

        var attempts = 0
        while true {
            attempts += 1
            let code = try await sendPTP(
                cam, op: EOS.setDevicePropValueEx, params: [], data: payload,
                label: on ? "record start" : "record stop"
            ).response
            if code == EOS.respOK { return }
            if code == EOS.respDeviceBusy && attempts < 8 {
                try await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            throw CanonTetherError.ptp(op: on ? "Record start" : "Record stop", code: code)
        }
    }

    // MARK: - EOS protocol: connect handshake

    private func runHandshake(_ cam: ICCameraDevice) async {
        // Both didOpenSession and deviceDidBecomeReady can fire and each calls
        // here; this flag (set synchronously before the first await) makes sure
        // the handshake — and the event/keep-alive/Live View loops it starts —
        // runs exactly once per connection.
        guard !handshaking else { return }
        handshaking = true
        defer { handshaking = false }
        do {
            // PC-remote mode + event reporting: the same OpenSession-follow-up
            // sequence libgphoto2 performs before any EOS remote control. The
            // session reports "open" a beat before it actually accepts PTP, so
            // the first command is retried through that window (an empty/
            // "malformed" response just means "not ready yet") instead of being
            // dropped to the slow full-reconnect path.
            try await sendRemoteModeWithRetry(cam)
            _ = try await sendPTP(cam, op: EOS.setEventMode, params: [1], data: nil, label: "SetEventMode")
            // Advertise plenty of host capacity; some bodies refuse transfers
            // to a "full" host otherwise. Values are 0x1000-block counts.
            _ = try? await sendPTP(cam, op: EOS.pcHDDCapacity,
                                   params: [0x0FFFFFFF, 0x1000, 0x1], data: nil, label: "PCHDDCapacity")
            // Drain whatever is queued so stale events don't confuse a take.
            _ = try? await fetchEvents(cam)

            status = .ready(name: cameraName)
            print("RobotArm 🎥 Canon handshake complete — \(cameraName) ready (+\(elapsed())ms after discovery)")
            startEventLoop(cam)
            startKeepAlive(cam)
            startLiveView(cam)
        } catch {
            // A transport/"malformed response" failure here usually means the
            // ImageCaptureCore link dropped mid-handshake — recover with a fresh
            // browser rather than dead-ending on a permanent failure.
            scheduleRecovery(reason: "handshake — \(error.localizedDescription)")
        }
    }

    // MARK: - EOS protocol: Live View (EVF over USB)

    /// Route the electronic viewfinder to the host and begin pulling frames.
    /// On EOS bodies the rear screen feed is sent over USB as a packed blob of
    /// JPEG frames; we pull one per loop, extract the JPEG, and publish it.
    private func startLiveView(_ cam: ICCameraDevice) {
        guard liveViewTask == nil else { return }
        liveViewRunning = true
        liveViewPaused = false
        liveViewDiag = 0
        liveViewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Route the EVF to the host. EVFOutputDevice alone starts Live View;
            // the separate EVFMode write isn't needed (the body reports "busy"
            // for it right after connect) so we skip it.
            do {
                try await self.setEOSProperty(cam, prop: EOS.propEVFOutputDevice, value: EOS.evfOutputPC, label: "EVFOutputDevice")
                print("RobotArm 🎥 Canon Live View enable sent (EVF→PC)")
            } catch {
                print("RobotArm ⚠️ Canon EVF enable failed — \(error.localizedDescription)")
            }
            // The body needs a beat and an event pump before frames are ready.
            _ = try? await self.fetchEvents(cam)

            while !Task.isCancelled {
                guard self.camera === cam else { return }
                // Idle the pulls while the QR scanner owns the camera stack, and
                // during the card download — so we're not hammering the
                // ImageCaptureCore channel when other subsystems need it (that
                // contention is what was invalidating the camera connection).
                if self.liveViewPaused || self.phase == .transferring {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    continue
                }
                if let jpeg = try? await self.pullViewFinderJPEG(cam),
                   let image = UIImage(data: jpeg) {
                    self.previewImage = image
                    // ~20 fps target; the round trip itself eats some of this.
                    try? await Task.sleep(nanoseconds: 33_000_000)
                } else {
                    // No frame yet (camera warming up / busy) — back off a bit.
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    /// Idle/resume the EVF pulls without tearing Live View down. Called around
    /// the QR scanner so the camera stack isn't contended during a scan.
    func pauseLiveView() { liveViewPaused = true }
    func resumeLiveView() { liveViewPaused = false }

    /// Recover from a dropped ImageCaptureCore connection. A re-opened-but-stale
    /// ICCameraDevice returns empty/"malformed" PTP responses, so the only
    /// reliable fix is a fresh browser → fresh device. Debounced.
    private func scheduleRecovery(reason: String) {
        guard !recovering else { return }
        recovering = true
        print("RobotArm ⚠️ Canon connection lost (\(reason)) — reconnecting")
        Task { @MainActor in
            self.stop()
            // Short settle so the USB stack releases the old handle, then
            // re-browse. Kept brief to minimize reconnect time at the event.
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.recovering = false
            self.start()
        }
    }

    private func stopLiveView() {
        liveViewTask?.cancel()
        liveViewTask = nil
        liveViewRunning = false
        previewImage = nil
        // Best-effort: turn the EVF routing back off so the camera's rear screen
        // resumes normally. Fire-and-forget — the camera may already be gone.
        if let cam = camera {
            Task { @MainActor in
                try? await self.setEVFOutputDevice(cam, value: 0)
            }
        }
    }

    /// Set one EOS UInt32 device property via SetDevicePropValueEx.
    /// Data-phase layout: [u32 total-len = 12][u32 property-code][u32 value].
    private func setEOSProperty(_ cam: ICCameraDevice, prop: UInt32, value: UInt32, label: String) async throws {
        var payload = Data()
        payload.appendU32(12)
        payload.appendU32(prop)
        payload.appendU32(value)
        let code = try await sendPTP(
            cam, op: EOS.setDevicePropValueEx, params: [], data: payload,
            label: label).response
        guard code == EOS.respOK else {
            throw CanonTetherError.ptp(op: label, code: code)
        }
    }

    private func setEVFOutputDevice(_ cam: ICCameraDevice, value: UInt32) async throws {
        try await setEOSProperty(cam, prop: EOS.propEVFOutputDevice, value: value, label: "EVFOutputDevice")
    }

    /// One GetViewFinderData round trip → the JPEG frame inside the blob. Logs
    /// the raw response code + byte count for the first several pulls so a
    /// no-preview failure is diagnosable from the console (camera-not-ready vs
    /// wrong opcode vs JPEG-not-found).
    private func pullViewFinderJPEG(_ cam: ICCameraDevice) async throws -> Data? {
        let (code, data) = try await sendPTP(
            cam, op: EOS.getViewFinderData, params: [EOS.viewFinderFlag],
            data: nil, label: "GetViewFinderData")
        let diag = liveViewDiag < 8
        if diag {
            liveViewDiag += 1
            print(String(format: "RobotArm 🎥 EVF pull #%d resp=0x%04X bytes=%d",
                         liveViewDiag, code, data?.count ?? 0))
        }
        guard code == EOS.respOK, let data else { return nil }
        let jpeg = Self.extractJPEG(from: data)
        if jpeg == nil && diag {
            print("RobotArm ⚠️ EVF frame carried no JPEG markers (bytes=\(data.count))")
        }
        return jpeg
    }

    /// The EVF blob wraps the frame in Canon's record structure, but the most
    /// body-independent way to recover the image is to lift the bytes between
    /// the JPEG start-of-image (FFD8) and the last end-of-image (FFD9) marker.
    private static func extractJPEG(from data: Data) -> Data? {
        guard let start = data.range(of: Data([0xFF, 0xD8])) else { return nil }
        guard let end = data.range(
            of: Data([0xFF, 0xD9]), options: .backwards,
            in: start.lowerBound..<data.endIndex) else { return nil }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }

    /// SetRemoteMode, retried through the brief not-ready window right after the
    /// session opens. Usually succeeds on the second attempt (~300 ms) — far
    /// cheaper than bouncing the whole connection (the ~2s full-recovery path)
    /// just because the camera wasn't ready for the very first command.
    private func sendRemoteModeWithRetry(_ cam: ICCameraDevice) async throws {
        var lastError: Error?
        for _ in 0..<6 {
            guard self.camera === cam else { throw CanonTetherError.notConnected }
            do {
                _ = try await sendPTP(cam, op: EOS.setRemoteMode, params: [1], data: nil, label: "SetRemoteMode")
                return
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        throw lastError ?? CanonTetherError.timeout("camera to accept commands")
    }

    /// Continuously drain the camera's event queue AND act as the connection
    /// health monitor. EOS bodies expect the host to poll GetEvent; new-file
    /// announcements arrive in these blobs. Crucially, a dead ImageCaptureCore
    /// link (e.g. the XPC `Code=4099` invalidation) fires NO delegate callback —
    /// the only symptom is that commands start throwing. So if several polls in
    /// a row fail while we're idle, we force a recovery (fresh browser →
    /// reconnect) instead of sitting on a dead connection until someone restarts
    /// the camera. Mid-capture drops are left to the capture's own error
    /// handling, so we don't abort a take that's already failing gracefully.
    private func startEventLoop(_ cam: ICCameraDevice) {
        eventLoopTask?.cancel()
        eventLoopTask = Task { @MainActor [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                guard let self, self.camera === cam else { return }
                do {
                    let events = try await self.fetchEvents(cam)
                    self.pendingObjects.append(contentsOf: events)
                    consecutiveFailures = 0
                } catch {
                    consecutiveFailures += 1
                    if consecutiveFailures >= 4 && self.phase == .idle {
                        print("RobotArm ⚠️ Canon link looks dead (\(consecutiveFailures) failed polls) — auto-recovering")
                        self.scheduleRecovery(reason: "link health check")
                        return
                    }
                }
                // Poll fast while failing (detect a dead link in ~1.5s) or during
                // a take; slow when idle and healthy.
                let interval: UInt64 = consecutiveFailures > 0 ? 400_000_000
                    : (self.phase == .idle ? 900_000_000 : 250_000_000)
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func startKeepAlive(_ cam: ICCameraDevice) {
        keepAliveTask?.cancel()
        keepAliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, self.camera === cam else { return }
                _ = try? await self.sendPTP(cam, op: EOS.keepDeviceOn, params: [], data: nil, label: "KeepDeviceOn")
            }
        }
    }

    /// One GetEvent round trip → any new-object records found in the blob.
    private func fetchEvents(_ cam: ICCameraDevice) async throws -> [NewObject] {
        let (code, data) = try await sendPTP(cam, op: EOS.getEvent, params: [], data: nil, label: "GetEvent")
        guard code == EOS.respOK, let data else { return [] }
        return Self.parseNewObjects(from: data)
    }

    /// Wait until the event stream announces the clip recorded by this take.
    private func waitForNewMovieObject(_ cam: ICCameraDevice, timeout: TimeInterval) async throws -> NewObject {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Movie files report a video object format / .MP4 name. If the
            // format code lies, fall back to "any new object" — during a
            // tethered movie take nothing else gets written.
            if let i = pendingObjects.firstIndex(where: { $0.looksLikeMovie }) {
                return pendingObjects.remove(at: i)
            }
            if let events = try? await fetchEvents(cam) {
                pendingObjects.append(contentsOf: events)
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        if !pendingObjects.isEmpty { return pendingObjects.removeFirst() }
        throw CanonTetherError.timeout("the camera to register the recorded clip")
    }

    // MARK: - EOS protocol: still capture

    /// Fire the real shutter, wait for the JPEG to land on the card, pull it, delete it.
    ///
    /// 🔑 **The same three steps the movie path takes, for one frame.** Ported from PivotBooth's
    /// still booth (`CanonTetherController.captureStill`), proven on this R8. The card delete is
    /// best-effort and runs after the download so an event's worth of guests never fills the card.
    func captureStill() async throws -> UIImage {
        guard let cam = camera, case .ready = status else { throw CanonTetherError.notConnected }
        guard phase == .idle else { throw CanonTetherError.alreadyRecording }
        pendingObjects.removeAll()

        // Drain the single PTP channel so the shutter never queues behind a live-view frame —
        // this is what made the "fast first shot, slow second" inconsistency go away.
        await ptpGate.wait(); ptpGate.signal()
        _ = try? await fetchEvents(cam)
        pendingObjects.removeAll()

        let t0 = Date()
        try await remoteRelease(cam)
        let tShutter = Date()
        let object = try await waitForNewPhotoObject(cam, timeout: 15)
        let tRegister = Date()
        let url = try await download(object, from: cam) { _ in }
        let tDownload = Date()
        Log.write(String(format: "canon: still — shutter %.0fms · register %.0fms · download %.0fms",
                         tShutter.timeIntervalSince(t0) * 1000,
                         tRegister.timeIntervalSince(tShutter) * 1000,
                         tDownload.timeIntervalSince(tRegister) * 1000))
        Task { await self.deleteCardObject(object.handle, from: cam) }

        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            throw CanonTetherError.transfer("could not decode the captured JPEG")
        }
        try? FileManager.default.removeItem(at: url)
        return image
    }

    /// Press and release, retrying through Device-Busy the way the camera needs after a shot.
    private func remoteRelease(_ cam: ICCameraDevice) async throws {
        var attempts = 0
        while true {
            attempts += 1
            let code = try await sendPTP(cam, op: EOS.remoteReleaseOn, params: [0x3, 0x0],
                                         data: nil, label: "RemoteReleaseOn").response
            if code == EOS.respOK {
                if attempts > 1 { Log.write("canon: shutter fired after \(attempts) tries (camera was busy)") }
                _ = try? await sendPTP(cam, op: EOS.remoteReleaseOff, params: [0x3],
                                       data: nil, label: "RemoteReleaseOff")
                return
            }
            _ = try? await sendPTP(cam, op: EOS.remoteReleaseOff, params: [0x3], data: nil, label: "RemoteReleaseOff")
            if code == EOS.respDeviceBusy && attempts < 18 {
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            Log.write("canon: shutter gave up after \(attempts) tries — 0x\(String(format: "%04X", code))")
            throw CanonTetherError.ptp(op: "Shutter", code: code)
        }
    }

    /// Wait until the event stream announces the JPEG from this shot.
    private func waitForNewPhotoObject(_ cam: ICCameraDevice, timeout: TimeInterval) async throws -> NewObject {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let i = pendingObjects.firstIndex(where: { !$0.looksLikeMovie }) {
                return pendingObjects.remove(at: i)
            }
            if let events = try? await fetchEvents(cam) { pendingObjects.append(contentsOf: events) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if !pendingObjects.isEmpty { return pendingObjects.removeFirst() }
        throw CanonTetherError.timeout("the camera to register the photo")
    }

    // MARK: - EOS protocol: download

    /// Chunked GetPartialObject download to a temp file, then TransferComplete.
    /// Chunks retry individually so one USB hiccup doesn't scrap a 100 MB clip.
    private func download(
        _ object: NewObject, from cam: ICCameraDevice,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-canon-\(UUID().uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: tmp)
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tmp) else {
            throw CanonTetherError.transfer("can't create local file")
        }
        defer { try? handle.close() }

        let chunkSize: UInt32 = 1 << 20   // 1 MB
        var offset: UInt64 = 0
        while true {
            var chunk: Data? = nil
            var lastError: Error? = nil
            for attempt in 1...3 {
                do {
                    let (code, data) = try await sendPTP(
                        cam, op: EOS.getPartialObject,
                        params: [object.handle, UInt32(truncatingIfNeeded: offset), chunkSize],
                        data: nil, label: "GetPartialObject")
                    guard code == EOS.respOK else {
                        throw CanonTetherError.ptp(op: "Download", code: code)
                    }
                    chunk = data ?? Data()
                    break
                } catch {
                    lastError = error
                    print("RobotArm ⚠️ Canon chunk @\(offset) attempt \(attempt)/3 failed — \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            guard let chunk else {
                throw lastError ?? CanonTetherError.transfer("chunk download failed")
            }
            if !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
                offset += UInt64(chunk.count)
            }
            if object.size > 0 {
                progress(min(1, Double(offset) / Double(object.size)))
                if offset >= object.size { break }
            }
            if chunk.count < Int(chunkSize) { break }   // short read = end of file
        }

        _ = try? await sendPTP(cam, op: EOS.transferComplete, params: [object.handle], data: nil, label: "TransferComplete")
        print("RobotArm 🎥 Canon downloaded \(offset / 1_048_576) MB")
        guard offset > 0 else { throw CanonTetherError.transfer("camera returned an empty file") }
        return tmp
    }

    /// Best-effort delete of a card object after it's been downloaded. Keeps the
    /// card from filling over a long event (which slows every reconnect's
    /// enumeration). Never throws — a failed delete just leaves the file behind.
    private func deleteCardObject(_ handle: UInt32, from cam: ICCameraDevice) async {
        let code = (try? await sendPTP(cam, op: EOS.deleteObject,
                                       params: [handle], data: nil, label: "DeleteObject").response) ?? 0
        if code == EOS.respOK {
            print("RobotArm 🎥 Canon: card object 0x\(String(handle, radix: 16)) deleted")
        } else {
            print("RobotArm ⚠️ Canon: card delete returned 0x\(String(format: "%04X", code)) — left on card")
        }
    }

    // MARK: - PTP plumbing

    /// Send one vendor PTP operation through ImageCaptureCore and return the
    /// response code plus any data-in payload.
    private func sendPTP(
        _ cam: ICCameraDevice, op: UInt16, params: [UInt32], data: Data?, label: String
    ) async throws -> (response: UInt16, inData: Data?) {
        // PTP command container: length, type(1=command), opcode, transaction
        // id (ImageCaptureCore assigns the real one), then up to 5 params.
        var cmd = Data()
        cmd.appendU32(UInt32(12 + 4 * params.count))
        cmd.appendU16(1)
        cmd.appendU16(op)
        cmd.appendU32(0)
        params.forEach { cmd.appendU32($0) }

        // Serialize: only one PTP transaction may be on the wire at a time.
        await ptpGate.wait()
        defer { ptpGate.signal() }

        return try await withCheckedThrowingContinuation { cont in
            cam.requestSendPTPCommand(cmd, outData: data) { inData, responseContainer, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                // Response container: u32 len, u16 type(3), u16 response code, …
                guard responseContainer.count >= 8 else {
                    cont.resume(throwing: CanonTetherError.transfer("\(label): malformed PTP response"))
                    return
                }
                let code = responseContainer.readU16(at: 6)
                cont.resume(returning: (code, inData.isEmpty ? nil : inData))
            }
        }
    }

    // MARK: - GetEvent parsing

    /// Walk the packed records in a GetEvent blob and pull out new-object
    /// announcements. Record layout (libgphoto2 ptp_unpack_CANON_changes):
    /// each record = [u32 size][u32 type][payload…], size includes the header;
    /// the list ends at a record with size < 8.
    private static func parseNewObjects(from data: Data) -> [NewObject] {
        var found: [NewObject] = []
        var off = 0
        while off + 8 <= data.count {
            let size = Int(data.readU32(at: off))
            let type = data.readU32(at: off + 4)
            guard size >= 8, off + size <= data.count else { break }

            switch type {
            case EOS.evtObjectAddedEx:
                // [u32 oid][u32 storage][u32 ofc][u32 …][u32 size]…[cstr name]
                if size >= 0x20 {
                    let oid = data.readU32(at: off + 8)
                    let storage = data.readU32(at: off + 12)
                    let ofc = data.readU32(at: off + 16)
                    let objSize = UInt64(data.readU32(at: off + 28))
                    let name = data.readCString(at: off + 32, limit: off + size)
                    found.append(NewObject(handle: oid, storageID: storage,
                                           formatCode: ofc, size: objSize, filename: name))
                }
            case EOS.evtObjectAddedEx64:
                // 64-bit variant used by newer bodies for big files.
                if size >= 0x28 {
                    let oid = data.readU32(at: off + 8)
                    let storage = data.readU32(at: off + 12)
                    let ofc = data.readU32(at: off + 16)
                    let objSize = data.readU64(at: off + 0x1C)
                    let name = data.readCString(at: off + 0x28, limit: off + size)
                    found.append(NewObject(handle: oid, storageID: storage,
                                           formatCode: ofc, size: objSize, filename: name))
                }
            default:
                break
            }
            off += size
        }
        return found
    }
}

private extension NewObject {
    /// True when the announced object is plausibly the recorded movie. Canon
    /// movie OFCs vary by body/container, so the filename is the robust check.
    var looksLikeMovie: Bool {
        let lower = filename.lowercased()
        if lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") { return true }
        // No/garbled filename — accept anything that isn't an obvious photo.
        if filename.isEmpty { return true }
        return !(lower.hasSuffix(".jpg") || lower.hasSuffix(".heif")
                 || lower.hasSuffix(".hif") || lower.hasSuffix(".cr3"))
    }
}

// MARK: - ImageCaptureCore delegates

extension CanonTetherController: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            guard self.camera == nil, let cam = device as? ICCameraDevice else { return }
            print("RobotArm 🎥 Canon: discovered \(device.name ?? "camera") (+\(self.elapsed())ms) — opening session")
            self.connectClock = Date()   // reset so open/handshake time reads per-connect
            self.camera = cam
            self.cameraName = device.name ?? "Canon"
            self.status = .connecting(name: self.cameraName)
            cam.delegate = self
            cam.requestOpenSession()
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            guard device === self.camera else { return }
            self.teardownConnection(reconnecting: self.browser != nil)
            print("RobotArm ⚠️ Canon disconnected")
        }
    }
}

extension CanonTetherController: ICCameraDeviceDelegate {
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        Task { @MainActor in
            guard device === self.camera, let cam = self.camera else { return }
            if let error {
                self.status = .failed("open session — \(error.localizedDescription)")
                return
            }
            print("RobotArm 🎥 Canon: session opened (+\(self.elapsed())ms) — handshaking")
            // Some bodies are ready immediately; deviceDidBecomeReady also
            // fires. runHandshake guards itself against double entry via status.
            if case .connecting = self.status {
                await self.runHandshake(cam)
            }
        }
    }

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in
            guard device === self.camera, let cam = self.camera else { return }
            if case .connecting = self.status {
                await self.runHandshake(cam)
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        Task { @MainActor in
            guard device === self.camera else { return }
            let reconnecting = { if case .disabled = self.status { return false } else { return self.browser != nil } }()
            self.teardownConnection(reconnecting: reconnecting)
        }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in
            guard device === self.camera else { return }
            let reconnecting = { if case .disabled = self.status { return false } else { return self.browser != nil } }()
            self.teardownConnection(reconnecting: reconnecting)
        }
    }

    // Content-catalog callbacks — unused (we track new files via the EOS event
    // stream), but required by the protocol.
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

// MARK: - HFR conform normalization

/// Canon writes High Frame Rate clips "conformed": a 5-second 179.8fps take is
/// stored as a ~30-second 29.97p file (slow motion baked in, no audio). The
/// app's timeline applies its own speed math, so a conformed file would get
/// slowed twice. This detects conformed clips by comparing file duration to
/// the wall-clock take length and rewrites the container with real-time
/// timestamps — a lossless remux (no re-encode), leaving a 179.8fps-timestamped
/// clip the pipeline treats exactly like a UVC recording.
enum CanonClipNormalizer {
    /// Conform factors Canon actually produces (HFR rate ÷ container rate).
    private static let knownFactors: [Double] = [2, 2.5, 3, 4, 5, 6]

    static func retimeIfConformed(url: URL, wallClockSeconds: Double) async throws -> URL {
        guard wallClockSeconds > 0.5 else { return url }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { return url }

        let ratio = duration / wallClockSeconds
        // Snap to a known conform factor; the wall clock includes start/stop
        // latency so allow generous tolerance. Ratio ≈ 1 → real-time file.
        guard let factor = knownFactors.first(where: { abs(ratio - $0) / $0 < 0.18 }) else {
            if ratio > 1.6 {
                print("RobotArm ⚠️ Canon clip ratio \(String(format: "%.2f", ratio)) looks conformed but matches no known factor — leaving as-is")
            }
            return url
        }
        print("RobotArm 🎥 Canon HFR clip conformed ×\(factor) (\(String(format: "%.1f", duration))s file / \(String(format: "%.1f", wallClockSeconds))s take) — retiming to real time")

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-canon-rt-\(UUID().uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: out)
        try await retime(asset: asset, by: factor, to: out)
        try? FileManager.default.removeItem(at: url)
        return out
    }

    /// Lossless remux with every sample's timestamps divided by `factor`.
    /// Compressed samples pass straight through (no decode), so this takes a
    /// fraction of a second even for 100 MB clips.
    private static func retime(asset: AVAsset, by factor: Double, to out: URL) async throws {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoProcessorError.noVideoTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil) // compressed passthrough
        output.alwaysCopiesSampleData = false
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let formats = try await videoTrack.load(.formatDescriptions)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                       sourceFormatHint: formats.first)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw VideoProcessorError.exportFailed("retime: can't add writer input")
        }
        writer.add(input)

        guard reader.startReading() else {
            throw VideoProcessorError.exportFailed(reader.error?.localizedDescription ?? "retime reader")
        }
        guard writer.startWriting() else {
            throw VideoProcessorError.exportFailed(writer.error?.localizedDescription ?? "retime writer")
        }
        writer.startSession(atSourceTime: .zero)

        while let sample = output.copyNextSampleBuffer() {
            guard let scaled = scaleTiming(of: sample, dividedBy: factor) else { continue }
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw VideoProcessorError.exportFailed(writer.error?.localizedDescription ?? "retime writer failed")
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            input.append(scaled)
        }
        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        guard writer.status == .completed else {
            throw VideoProcessorError.exportFailed(writer.error?.localizedDescription ?? "retime writer status \(writer.status.rawValue)")
        }
    }

    /// Copy a sample buffer with presentation/decode timestamps and duration
    /// all divided by `factor` (timescale-preserving).
    private static func scaleTiming(of sample: CMSampleBuffer, dividedBy factor: Double) -> CMSampleBuffer? {
        var count = CMItemCount(0)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0,
                                                     arrayToFill: nil,
                                                     entriesNeededOut: &count) == 0, count > 0 else { return nil }
        var info = [CMSampleTimingInfo](repeating: .init(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count,
                                                     arrayToFill: &info,
                                                     entriesNeededOut: nil) == 0 else { return nil }
        func scale(_ t: CMTime) -> CMTime {
            guard t.isValid else { return t }
            return CMTime(value: CMTimeValue((Double(t.value) / factor).rounded()), timescale: t.timescale)
        }
        for i in 0..<count {
            info[i].presentationTimeStamp = scale(info[i].presentationTimeStamp)
            info[i].decodeTimeStamp = scale(info[i].decodeTimeStamp)
            info[i].duration = scale(info[i].duration)
        }
        var outSample: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                              sampleBuffer: sample,
                                              sampleTimingEntryCount: count,
                                              sampleTimingArray: info,
                                              sampleBufferOut: &outSample)
        return outSample
    }
}

// MARK: - Little-endian Data helpers (PTP is little-endian)

private extension Data {
    mutating func appendU16(_ v: UInt16) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendU32(_ v: UInt32) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    func readU16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }
    func readU32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        var v: UInt32 = 0
        for i in (0..<4).reversed() { v = (v << 8) | UInt32(self[startIndex + offset + i]) }
        return v
    }
    func readU64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = (v << 8) | UInt64(self[startIndex + offset + i]) }
        return v
    }
    /// ASCII/UTF-8 C string starting at `offset`, stopping at NUL or `limit`.
    func readCString(at offset: Int, limit: Int) -> String {
        guard offset < count, offset < limit else { return "" }
        let end = Swift.min(limit, count)
        var bytes: [UInt8] = []
        var i = offset
        while i < end {
            let b = self[startIndex + i]
            if b == 0 { break }
            bytes.append(b)
            i += 1
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}

// MARK: - Async semaphore

/// A minimal FIFO async semaphore. Used to serialize PTP transactions so the
/// concurrent background loops (events, keep-alive, Live View, download) never
/// have two commands on the single ImageCaptureCore channel at once.
final class AsyncSemaphore: @unchecked Sendable {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    init(_ permits: Int) { self.permits = permits }

    func wait() async {
        lock.lock()
        if permits > 0 {
            permits -= 1
            lock.unlock()
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
            lock.unlock()
        }
    }

    func signal() {
        lock.lock()
        if waiters.isEmpty {
            permits += 1
            lock.unlock()
        } else {
            let cont = waiters.removeFirst()
            lock.unlock()
            cont.resume()
        }
    }
}

// MARK: - Live View SwiftUI preview

/// Renders the Canon EVF stream as the on-screen guest preview. The full frame
/// is shown letterboxed (aspect-fit) on black so the guest sees exactly what's
/// framed. Falls back to a status line until the first frame arrives.
struct CanonLivePreview: View {
    @ObservedObject var controller: CanonTetherController

    var body: some View {
        ZStack {
            Color.black
            if let image = controller.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.4)
                    Text(controller.liveViewRunning
                         ? "Starting Canon live view…"
                         : "Canon R8 — \(controller.statusLabel)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
        }
    }
}

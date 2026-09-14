import Combine
import Foundation
import SwiftUI

/// The one Canon the rest of the app talks to. It can reach the camera two ways and uses
/// whichever answers, so "it just connects" whatever the camera is set to:
///
///   1. **USB tether (PTP over the cable)** — `CanonTetherController`, the CanonPivotBot path.
///      Works with a plain USB-C cable, no camera-side network setup. This is preferred.
///   2. **CCAPI over the network** — `CanonCCAPI`, the PivotBooth path. Used when the camera is
///      on Wi-Fi (or in the USB Camera-Connect IP mode) and CCAPI is enabled.
///
/// Both are started at launch; the first to become ready is the source. Every screen and the
/// capture flow use this facade (`Canon.shared`), so nothing else has to know which won.
@MainActor
final class Canon: ObservableObject {
    static let shared = Canon()

    let tether = CanonTetherController()
    let ccapi = CanonCCAPI.shared

    private init() {
        // Republish whenever either transport changes, so SwiftUI views update.
        tether.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &sinks)
        ccapi.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &sinks)
    }
    private var sinks = Set<AnyCancellable>()

    /// Every IPv4 address the iPad holds, with its interface — used by the network watcher.
    nonisolated static func interfaces() -> [String] { CanonCCAPI.interfaces() }

    // MARK: What the app asks

    /// True when either transport has a live camera.
    var isReady: Bool { tether.isReadyToRecord || ccapi.isReady }

    /// The active transport, preferring the USB tether.
    private var usingTether: Bool { tether.isReadyToRecord || (!ccapi.isReady && tetherTrying) }
    private var tetherTrying: Bool {
        switch tether.status { case .searching, .connecting: return true; default: return false }
    }

    var previewImage: UIImage? {
        if tether.isReadyToRecord { return tether.previewImage }
        if ccapi.isReady { return ccapi.previewImage }
        return tether.previewImage ?? ccapi.previewImage
    }

    var recording: Bool { tether.phase == .recording || ccapi.recording }

    /// One line for the status strip / Camera section.
    var label: String {
        if tether.isReadyToRecord { return "\(tether.statusLabel) (USB)" }
        if ccapi.isReady { return "\(ccapi.label) (Wi-Fi)" }
        // Neither ready: show whichever is making progress, else both attempts.
        if tetherTrying { return tether.statusLabel }
        return "USB: \(tether.statusLabel) · Wi-Fi: \(ccapi.label)"
    }

    var lastSearch: String { ccapi.lastSearch }
    var knownHost: String {
        get { ccapi.knownHost }
        set { ccapi.knownHost = newValue }
    }

    // MARK: Lifecycle

    func start() {
        tether.start()
        ccapi.start()
        // Report the USB side to the log too (the CCAPI side already logs its scans).
        Task { @MainActor in
            var last = ""
            while true {
                let now = tether.statusLabel
                if now != last { Log.write("canon usb: \(now)"); last = now }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func searchAgain() {
        tether.stop(); tether.start()
        ccapi.searchAgain()
    }

    // MARK: Recording (routes to whichever is live)

    func startMovie() async throws {
        if tether.isReadyToRecord {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                tether.startRecording { c.resume(with: $0) }
            }
        } else if ccapi.isReady {
            try await ccapi.startMovie()
        } else {
            throw CanonError.notReady
        }
    }

    /// Stop recording and return the movie file on the iPad.
    func stopMovie() async throws -> URL {
        if tether.phase == .recording || tether.phase == .starting {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("canon-\(Int(Date().timeIntervalSince1970)).mov")
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                tether.stopRecordingAndFetch(to: dest, progress: { _ in }) { c.resume(with: $0) }
            }
        } else if ccapi.recording {
            return try await ccapi.stopMovie()
        } else {
            throw CanonError.notReady
        }
    }
}


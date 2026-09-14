import Darwin
import Foundation
import UIKit

/// The Canon on the arm, over Canon's CCAPI (its own HTTP API). Finds the camera on its own when
/// it is plugged in — over the USB-C hub it appears as an IP link at 192.0.0.1 — shows its live
/// view, and records the guest as a movie on the camera which is then pulled onto the iPad for
/// the video template. Client trimmed from PivotBooth's `CCAPICamera`, which was proven against
/// this camera.
///
/// One-time on the camera: CCAPI enabled (Canon developer registration), and for the cable the
/// camera's USB connection set to the smartphone/Camera Connect mode so it presents the IP link.
@MainActor
final class Canon: ObservableObject {
    static let shared = Canon()

    enum Status: Equatable {
        case off
        case searching
        case ready(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var recording = false
    /// What the last search tried, for the Camera section.
    @Published private(set) var lastSearch = ""

    var isReady: Bool { if case .ready = status { return true }; return false }
    var label: String {
        switch status {
        case .off: return "off"
        case .searching: return "looking for the Canon…"
        case .ready(let n): return "\(n) ready"
        case .failed(let m): return m
        }
    }

    private var base: URL?
    private var ver = "ver100"
    private var searchTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var busy = false

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c, delegate: CanonTrust(), delegateQueue: nil)
    }()

    // MARK: Finding it

    /// Keep looking until the camera answers; once it does, start the live view. Retries every
    /// 5 s while it is not there, so plugging it in later is enough.
    func start() {
        guard searchTask == nil else { return }
        status = .searching
        searchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isReady {
                    if let found = await self.discover() {
                        self.base = found
                        await self.connect()
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() {
        searchTask?.cancel(); searchTask = nil
        liveTask?.cancel(); liveTask = nil
        previewImage = nil
        base = nil
        status = .off
    }

    /// Drop and look again — for the Camera section's button.
    func searchAgain() {
        stop()
        start()
    }

    private func connect() async {
        do {
            let info = try await getJSON("/ccapi/")
            if info["ver110"] != nil { ver = "ver110" }
            var name = "Canon"
            if let dev = try? await getJSON("/ccapi/\(ver)/deviceinformation"),
               let product = dev["productname"] as? String { name = product }
            try await postJSON("/ccapi/\(ver)/shooting/liveview",
                               body: ["liveviewsize": "medium", "cameradisplay": "on"])
            status = .ready(name)
            Log.write("canon: found \(name) at \(base?.absoluteString ?? "?")")
            startLiveView()
        } catch {
            status = .failed("Canon answered but would not start: \(error.localizedDescription)")
            Log.write("canon: connect failed — \(error.localizedDescription)")
            base = nil
        }
    }

    /// Probe the likely addresses. 192.0.0.1 first — that is where a Canon lands over a USB-C IP
    /// link (the iPad gets 192.0.0.2). Then the usual spots on every interface the iPad has. The
    /// rail and the arm are never probed.
    private func discover() async -> URL? {
        var candidates = ["192.0.0.1"]
        for ip in localIPv4s() {
            let parts = ip.split(separator: ".")
            guard parts.count == 4, let last = Int(parts[3]) else { continue }
            let prefix = parts.prefix(3).joined(separator: ".")
            candidates += ["\(prefix).1", "\(prefix).2", "\(prefix).254"]
            if last - 1 >= 1 { candidates.append("\(prefix).\(last - 1)") }
        }
        candidates.append("192.168.4.1")
        let rig: Set<String> = [RailLink.host, ArmLink.host]

        var tried: [String] = []
        var seen = Set<String>()
        for ip in candidates where !rig.contains(ip) && seen.insert(ip).inserted {
            for baseStr in ["http://\(ip):8080", "https://\(ip):443"] {
                guard let url = URL(string: baseStr) else { continue }
                var req = URLRequest(url: url.appendingPathComponent("ccapi/"))
                req.timeoutInterval = 2
                if let (_, resp) = try? await session.data(for: req),
                   let http = resp as? HTTPURLResponse, http.statusCode < 500 {
                    lastSearch = "found at \(baseStr)"
                    return url
                }
                tried.append(ip)
            }
        }
        lastSearch = tried.isEmpty ? "no addresses to try" : "nothing at " + Array(Set(tried)).sorted().joined(separator: ", ")
        return nil
    }

    private func localIPv4s() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard String(cString: ptr.pointee.ifa_name) != "lo0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254") { out.append(ip) }
            }
        }
        return out
    }

    // MARK: Live view

    private func startLiveView() {
        guard liveTask == nil else { return }
        liveTask = Task { @MainActor [weak self] in
            var misses = 0
            while !Task.isCancelled {
                guard let self else { return }
                if self.busy { try? await Task.sleep(nanoseconds: 100_000_000); continue }
                if let data = try? await self.getData("/ccapi/\(self.ver)/shooting/liveview/flip"),
                   let img = UIImage(data: data) {
                    self.previewImage = img
                    misses = 0
                    try? await Task.sleep(nanoseconds: 33_000_000)
                } else {
                    misses += 1
                    if misses >= 40 {                       // ~5 s of nothing: the cable is out
                        Log.write("canon: live view lost — looking again")
                        self.liveTask = nil
                        self.base = nil
                        self.previewImage = nil
                        self.status = .searching
                        return
                    }
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
            }
        }
    }

    // MARK: Recording

    /// Start a movie on the camera. Switches it to movie mode first.
    func startMovie() async throws {
        guard isReady else { throw CanonError.notReady }
        busy = true
        defer { busy = false }
        _ = try? await postJSON("/ccapi/\(ver)/shooting/control/moviemode", body: ["status": "on"])
        // Clear queued events so the file we wait for is this recording's.
        _ = try? await getJSON("/ccapi/\(ver)/event/polling?timeout=immediately")
        try await postJSON("/ccapi/\(ver)/shooting/control/recbutton", body: ["action": "start"])
        recording = true
        Log.write("canon: recording")
    }

    /// Stop, wait for the camera to announce the file, pull it to the iPad, delete it on the card.
    func stopMovie() async throws -> URL {
        busy = true
        defer { busy = false; recording = false }
        try await postJSON("/ccapi/\(ver)/shooting/control/recbutton", body: ["action": "stop"])
        let path = try await waitForNewMovie(timeout: 20)
        let data = try await getData(path + "?kind=main")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("canon-\(Int(Date().timeIntervalSince1970)).mp4")
        try data.write(to: url)
        Task { _ = try? await self.request(path, method: "DELETE") }
        Log.write("canon: movie pulled — \(data.count / 1_000_000) MB")
        return url
    }

    private func waitForNewMovie(timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let ev = try await getJSON("/ccapi/\(ver)/event/polling?timeout=long")
            if let added = ev["addedcontents"] as? [String],
               let mov = added.first(where: { $0.lowercased().hasSuffix(".mp4") || $0.lowercased().hasSuffix(".mov") }) ?? added.first {
                return mov
            }
        }
        throw CanonError.timeout
    }

    // MARK: HTTP

    private func getJSON(_ path: String) async throws -> [String: Any] {
        let data = try await request(path, method: "GET")
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func getData(_ path: String) async throws -> Data {
        try await request(path, method: "GET")
    }

    @discardableResult
    private func postJSON(_ path: String, body: [String: Any]) async throws -> Data {
        try await request(path, method: "POST", body: try JSONSerialization.data(withJSONObject: body))
    }

    @discardableResult
    private func request(_ path: String, method: String, body: Data? = nil) async throws -> Data {
        guard let base, let url = URL(string: path, relativeTo: base) else { throw CanonError.notReady }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CanonError.http(0, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw CanonError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return data
    }
}

enum CanonError: Error, LocalizedError {
    case notReady, timeout, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .notReady: return "The Canon is not connected"
        case .timeout: return "The Canon did not announce the movie file"
        case .http(let c, let m): return "Canon HTTP \(c): \(m)"
        }
    }
}

/// The camera's HTTPS uses its own certificate; this is a direct local link, so accept it.
private final class CanonTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

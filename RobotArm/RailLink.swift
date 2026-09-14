import Foundation
import Network

/// Talks to the Glamatic camera rail's Siemens PLC at https://192.168.1.2.
///
/// The rail's movements are stored INSIDE the PLC as numbered programs. This file can:
/// log in, read the PLC's status, start stored program N, and stop the rail.
/// Trimmed from the previous app's GlamaticLink, whose sequences were proven on the real rail.
@MainActor
final class RailLink: ObservableObject {
    static let shared = RailLink()

    static let host = "192.168.1.2"
    static let asciiPort: UInt16 = 2000
    static let username = "Glamatic"          // factory default login
    static let password = "Glamatic"

    /// Tags in the PLC's "IOMotor" data block. "Velocety" is the vendor's spelling; keep it.
    enum Tag: String {
        case programNumber = "\"IOMotor\".ProgramNumber"
        case runProgram    = "\"IOMotor\".RunProgram"
        case execute       = "\"IOMotor\".Execute"
        case enable        = "\"IOMotor\".Enable"
        case manual        = "\"IOMotor\".Manual"
        case executeHoming = "\"IOMotor\".ExecuteHoming"
        case resetError    = "\"IOMotor\".ResetError"
    }

    /// True while a homing or fault-reset run is in progress, so buttons can say so.
    @Published private(set) var busy = ""

    /// Set when the carriage moved while this app was not driving it. Two apps can talk to
    /// this rail — PivotBooth on the other iPad has a Follow Me loop that moves it every second —
    /// and from the floor that looks exactly like "the rail is glitching". Named so nobody
    /// spends an afternoon blaming the control box.
    @Published private(set) var foreignMotion: String?
    private var lastSeen: (mm: Double, at: Date)?
    /// Movement before this moment is ours. A stored program keeps the carriage moving after
    /// the arm has finished — program 14 is still on its way back when the runner says Done —
    /// and that must not be reported as another app driving the rail.
    private var expectMotionUntil = Date.distantPast

    func expectMotion(seconds: Double) {
        expectMotionUntil = max(expectMotionUntil, Date().addingTimeInterval(seconds))
    }

    /// Wait until the carriage has been still for a moment (or `timeout` passes). Used after a
    /// program so "Done" means the whole rig, not just the arm.
    /// Wait until the carriage actually starts moving, and report how far it got. This is the
    /// booth's sync anchor: the arm launches off the rail's REAL motion, not off a countdown clock
    /// or the six-wire edge (which is missed most runs when the same program repeats). Anchoring to
    /// motion means the arm starts at the same rail position every run, which is what the video
    /// template depends on.
    func waitUntilMoving(timeout: Double = 12, threshold: Double = 3) async -> Bool {
        let t0 = Date()
        let start = Double(currentPosition) ?? 0
        while Date().timeIntervalSince(t0) < timeout {
            await refresh()
            if abs((Double(currentPosition) ?? 0) - start) > threshold {
                Log.write(String(format: "rail: moving — %.0f → %.0f mm, %.2f s after fired", start, Double(currentPosition) ?? 0, Date().timeIntervalSince(t0)))
                return true
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        Log.write("rail: never started moving within \(Int(timeout)) s")
        return false
    }

    func waitUntilStill(timeout: Double = 40) async {
        let t0 = Date()
        var last = Double(currentPosition) ?? 0
        var stillFor = 0.0
        while Date().timeIntervalSince(t0) < timeout {
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refresh()
            let now = Double(currentPosition) ?? 0
            if abs(now - last) <= 1.5 {
                stillFor += 0.4
                if stillFor >= 1.2, Date().timeIntervalSince(t0) >= 1.2 { return }
            } else {
                stillFor = 0
            }
            last = now
        }
    }

    @Published private(set) var connected = false
    @Published private(set) var lastError = ""
    /// Straight from the PLC's status page.
    @Published private(set) var programNum = "0"
    @Published private(set) var currentPosition = "0"
    @Published private(set) var homed = "0"
    @Published private(set) var statusError = "0"

    private let session: URLSession
    private var base: String { "https://\(Self.host)" }
    private var autoTask: Task<Void, Never>?

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 10
        // Do NOT limit connections per host: that hung against this PLC in the previous app.
        session = URLSession(configuration: cfg,
                             delegate: PLCTrustDelegate(host: Self.host),
                             delegateQueue: nil)
    }

    // MARK: - Auto-connect

    /// Every 5 s: log in if we are not, otherwise read the status page (which also proves the
    /// session is still alive).
    func startAutoConnect() {
        guard autoTask == nil else { return }
        autoTask = Task { @MainActor in
            while !Task.isCancelled {
                if !connected {
                    _ = await handshake()
                } else {
                    _ = await refresh()
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Intro page → ENTER → try reading. If that is not JSON, log in and read again.
    private func handshake() async -> Bool {
        guard await get("\(base)/Portal/Intro.mwsl") else {
            connected = false
            return false
        }
        _ = await get("\(base)/Portal/Portal.mwsl?intro_enter_button=ENTER&PriNav=Start&coming_from_intro=true")
        if await refresh() { return true }
        return await login()
    }

    private func login() async -> Bool {
        if let c = HTTPCookie(properties: [
            .domain: Self.host, .path: "/", .name: "coming_from_login", .value: "true"
        ]) { HTTPCookieStorage.shared.setCookie(c) }

        guard let url = URL(string: "\(base)/FormLogin") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("\(base)/Portal/Portal.mwsl", forHTTPHeaderField: "Referer")
        req.setValue(base, forHTTPHeaderField: "Origin")
        req.httpBody = "Redirection=&Login=\(form(Self.username))&Password=\(form(Self.password))".data(using: .utf8)

        guard let (_, resp) = try? await session.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode, (200...399).contains(code) else {
            lastError = "Rail login was rejected"
            Log.write("rail: login rejected")
            return false
        }
        if await refresh() { return true }
        // The PLC accepted the login but gave no session: its small session pool is full.
        // It frees itself after ~30 minutes idle, or on a power cycle.
        lastError = "Rail is out of login slots. Wait 30 min or power-cycle the rail box."
        return false
    }

    private func form(_ v: String) -> String {
        v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
    }

    private func get(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        guard let (_, resp) = try? await session.data(from: url),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return false }
        return code > 0
    }

    // MARK: - Read

    /// Read the PLC's status JSON. If the page is not JSON the session has expired.
    @discardableResult
    func refresh() async -> Bool {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        guard let url = URL(string: "\(base)/awp/Glamatic/IOServer.htm?_=\(stamp)"),
              let (data, _) = try? await session.data(from: url),
              let text = String(data: data, encoding: .utf8) else {
            connected = false
            return false
        }
        guard let start = text.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: String] else {
            connected = false
            return false
        }
        programNum      = obj["ProgramNum"] ?? "0"
        currentPosition = obj["CurrentPosition"] ?? "0"
        homed           = obj["StatusHomed"] ?? "0"
        statusError     = obj["StatusError"] ?? "0"
        if !connected { Log.write("rail: connected — at \(currentPosition) mm, homed \(homed), error \(statusError)") }
        connected = true
        watchForForeignMotion()
        return true
    }

    // MARK: - Write

    /// Write one tag. HTTP 200 is NOT proof: without a session the PLC drops writes silently,
    /// which is why `connected` is checked too.
    @discardableResult
    func write(_ tag: Tag, _ value: String) async -> Bool {
        guard connected else { return false }
        guard let url = URL(string: "\(base)/awp/Glamatic/IOServer.htm") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encodedTag = tag.rawValue
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) ?? tag.rawValue
        req.httpBody = "\(encodedTag)=\(value)".data(using: .utf8)
        guard let (_, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return true
    }

    /// Start the rail's stored program `number` (0–63). The exact sequence the vendor's own
    /// RUN PROGRAM button performs, plus a check that the number was accepted.
    ///
    /// Manual MUST be 0: a stored program is an "automatic mode" action and the PLC silently
    /// ignores RunProgram while Manual is 1. RunProgram MUST be pulsed back to 0, otherwise the
    /// rail re-runs the program forever.
    func runProgram(_ number: Int) async -> Bool {
        let n = min(63, max(0, number))
        Log.write("rail: run program \(n) (at \(currentPosition) mm, homed \(homed))")
        expectMotion(seconds: 45)
        _ = await write(.manual, "0")
        _ = await write(.enable, "1")
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard await write(.programNumber, String(n)) else { return false }
        try? await Task.sleep(nanoseconds: 250_000_000)
        await refresh()
        guard programNum == String(n) else {
            lastError = "Rail did not accept program \(n) (it reads \(programNum))"
            return false
        }
        // 🔑 **The RunProgram 1→0 PULSE is the whole point — it makes the PLC drop and re-raise the
        // six wires, and that edge (≠n → n) is the arm's cue.** Build 126 replaced this with a raw
        // port-2000 packet to shave latency; the packet does NOT reproduce the edge, so the wires
        // sat at the last program number, the watcher timed out at 15 s every run, and the rig ran
        // wrong. Never trade this pulse for the raw trigger. Latency is hidden by firing during the
        // countdown (see Booth.run), not by changing the trigger.
        let fired = await write(.runProgram, "1")
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = await write(.runProgram, "0")
        return fired
    }

    /// Compare this reading with the last one. Movement while nothing here is running is
    /// somebody else's, and it is said on screen and in the log.
    private func watchForForeignMotion() {
        let now = Date()
        let mm = Double(currentPosition) ?? 0
        defer { lastSeen = (mm, now) }
        guard let last = lastSeen else { return }
        let ours = Runner.shared.running || !busy.isEmpty || now < expectMotionUntil
        if !ours, abs(mm - last.mm) > 3 {
            if foreignMotion == nil {
                Log.write(String(format: "rail: MOVED %.0f → %.0f mm with nothing running here — another app is driving it", last.mm, mm))
            }
            foreignMotion = "Something else is moving the rail — check PivotBooth on the other iPad"
        } else if foreignMotion != nil, now.timeIntervalSince(last.at) > 0, abs(mm - last.mm) <= 3 {
            // Still for one poll: clear it, so the note describes now rather than earlier.
            foreignMotion = nil
        }
    }

    /// Reference the rail: run the control box's own homing so it knows where the carriage is.
    ///
    /// Homing is lost on every power cycle, and the control box refuses to run a program until
    /// the rail is referenced — the status strip's "not homed" is exactly that state. The
    /// sequence is the one proven on this rail (the previous app's `referenceRail`): clear every
    /// trigger, de-energise, energise in MANUAL (homing is a manual-mode action and the PLC
    /// ignores it otherwise), pulse ExecuteHoming, then watch StatusHomed. Every trigger on this
    /// machine is pulsed; a level left high is what caused a runaway.
    ///
    /// The rail MOVES — to its reference switch and back.
    @discardableResult
    func home() async -> Bool {
        guard connected, busy.isEmpty else { return false }
        busy = "Homing"
        defer { busy = "" }
        Log.write("rail: homing")
        expectMotion(seconds: 70)
        for tag in [Tag.runProgram, .execute, .executeHoming] { _ = await write(tag, "0") }
        _ = await write(.enable, "0")
        _ = await write(.manual, "0")
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        _ = await write(.manual, "1")
        _ = await write(.enable, "1")
        try? await Task.sleep(nanoseconds: 500_000_000)
        _ = await write(.executeHoming, "1")
        try? await Task.sleep(nanoseconds: 400_000_000)
        _ = await write(.executeHoming, "0")

        let deadline = Date().addingTimeInterval(60)
        var ok = false
        while Date() < deadline {
            await refresh()
            if homed == "1" { ok = true; break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // Back to automatic mode so a stored program can run; homing stays referenced. Enable is
        // still up from the homing sequence, so the gate is ready and every run from here can go
        // straight to the raw trigger.
        _ = await write(.manual, "0")
        Log.write("rail: homing finished — homed \(homed), at \(currentPosition) mm")
        if !ok { lastError = "The rail did not report homed within 60 s" }
        return ok
    }

    /// Clear a latched fault on the control box.
    ///
    /// ResetError fires on a 0→1 edge, so it is pulsed low then high then low. A bare 1 written
    /// while it is already 1 makes no edge and the fault stays — seen after an E-stop.
    @discardableResult
    func clearFault() async -> Bool {
        guard connected, busy.isEmpty else { return false }
        busy = "Clearing fault"
        defer { busy = "" }
        Log.write("rail: clearing fault (was \(statusError))")
        _ = await write(.resetError, "0")
        try? await Task.sleep(nanoseconds: 150_000_000)
        let ok = await write(.resetError, "1")
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = await write(.resetError, "0")
        try? await Task.sleep(nanoseconds: 500_000_000)
        await refresh()
        Log.write("rail: fault now \(statusError)")
        return ok
    }

    /// Stop the rail, every way we have, in the order that matters.
    func stop() async {
        _ = await write(.enable, "0")
        await rawStop()
        for tag in [Tag.runProgram, .execute, .executeHoming] { _ = await write(tag, "0") }
        _ = await write(.manual, "0")
    }

    /// The raw trigger port needs no login: bytes "1" then a digit. "10" = program 0 = stop.
    private func rawStop() async {
        guard let port = NWEndpoint.Port(rawValue: Self.asciiPort) else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(Self.host), port: port, using: .tcp)
            var finished = false
            func done() {
                guard !finished else { return }
                finished = true
                conn.cancel()
                cont.resume()
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    conn.send(content: "10".data(using: .ascii), completion: .contentProcessed { _ in done() })
                case .failed, .cancelled: done()
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { done() }
        }
    }
}

/// Accept the PLC's self-signed certificate, for that one host only.
private final class PLCTrustDelegate: NSObject, URLSessionDelegate {
    let host: String
    init(host: String) { self.host = host }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

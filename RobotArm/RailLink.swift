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
        connected = true
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
        let fired = await write(.runProgram, "1")
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = await write(.runProgram, "0")
        return fired
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

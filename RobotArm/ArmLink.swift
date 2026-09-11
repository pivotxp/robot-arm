import Foundation
import Network

/// Talks to the UFACTORY xArm 5 at 192.168.1.231, port 502 (the arm's own binary protocol).
///
/// Trimmed from the previous app's XArmLink, whose wire format was proven against this arm.
/// This file only knows how to: connect, enable, send moves, read state, and stop.
/// All numbers coming in are in human units (degrees, mm, seconds). Radians only exist here.
@MainActor
final class ArmLink: ObservableObject {
    static let shared = ArmLink()
    private init() {}

    static let host = "192.168.1.231"
    static let port: UInt16 = 502

    /// Function codes from the public xArm register map.
    private enum FC {
        static let motionEnable: UInt8 = 11
        static let setState:     UInt8 = 12
        static let getState:     UInt8 = 13
        static let getCmdNum:    UInt8 = 14
        static let getError:     UInt8 = 15
        static let cleanErr:     UInt8 = 16
        static let cleanWar:     UInt8 = 17
        static let setMode:      UInt8 = 19
        static let moveLine:     UInt8 = 21
        static let moveLineB:    UInt8 = 22
        static let moveJoint:    UInt8 = 23
        static let moveJointB:   UInt8 = 24
        static let moveHome:     UInt8 = 25
        static let sleep:        UInt8 = 26
        static let setTcpOffset: UInt8 = 35
        static let setLoad:      UInt8 = 36
        static let getTcpPose:   UInt8 = 41
        static let getJointPos:  UInt8 = 42
        static let getInputs:    UInt8 = 131   // controller digital inputs (the rail's 6 signal wires)
    }

    @Published private(set) var connected = false
    /// 1 = moving, 2 = ready, 3 = paused, 4 = stopped. As the arm reports it.
    @Published private(set) var armState = 0
    /// The arm's own error code. 0 = none.
    @Published private(set) var errorCode = 0
    /// Last joint angles read from the arm, degrees. Empty until connected.
    @Published private(set) var joints: [Double] = []
    /// Goes up by one every time a connection is made. Lets the runner know when the arm has
    /// been power-cycled or re-plugged and needs the full enable sequence again.
    @Published private(set) var connectionGeneration = 0
    /// True once the servos are energised and ready to take live jog moves.
    @Published private(set) var enabled = false

    private var connection: NWConnection?
    private var tid: UInt16 = 0
    private var inflight = false
    private var autoTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?

    private enum ArmError: Error { case timeout }

    // MARK: - Auto-connect

    /// Keep trying to reach the arm every 3 s. Once connected, poll it every 3 s so a pulled
    /// cable is noticed (the read times out and the link drops, then we retry).
    func startAutoConnect() {
        guard autoTask == nil else { return }
        autoTask = Task { @MainActor in
            while !Task.isCancelled {
                if !connected {
                    _ = await connect()
                } else {
                    await refreshStatus()
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Read state, error and joints. Cheap; used by the poll and the run loop.
    func refreshStatus() async {
        guard connected else { return }
        if let s = await getState() { armState = s }
        if let e = await getError() { errorCode = e }
        if let j = await readJoints() { joints = j }
    }

    func connect() async -> Bool {
        if connected, connection != nil { return true }
        disconnect()
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return false }
        let conn = NWConnection(host: NWEndpoint.Host(Self.host), port: port, using: .tcp)
        connection = conn

        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var done = false
            func finish(_ v: Bool) {
                guard !done else { return }
                done = true
                cont.resume(returning: v)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:  finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(false) }
        }
        connected = ok
        if ok { connectionGeneration += 1; await refreshStatus() } else { disconnect() }
        return ok
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        connected = false
        enabled = false
        armState = 0
    }

    // MARK: - Live editing (jog the real arm, fast joint updates)

    /// While a pose editor is open, read the joints ~4x a second so the on-screen numbers and
    /// picture track the real arm as it is jogged.
    func startLivePolling() {
        guard liveTask == nil else { return }
        liveTask = Task { @MainActor in
            while !Task.isCancelled {
                if connected {
                    if let j = await readJoints() { joints = j }
                    if let s = await getState() { armState = s }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func stopLivePolling() {
        liveTask?.cancel()
        liveTask = nil
    }

    /// Energise the arm so it can be jogged live. Safe to call repeatedly.
    func ensureEnabled() async -> Bool {
        if enabled, armState == 1 || armState == 2 { return true }
        return await enable()
    }

    /// Nudge ONE joint by `deltaDeg` from where the arm is right now, at a gentle speed.
    /// Relative on purpose: a small step from the real position can't leap somewhere unreachable.
    @discardableResult
    func jogJoint(_ index: Int, _ deltaDeg: Double) async -> Bool {
        guard connected, enabled, index >= 0, index < 5 else { return false }
        var target = joints
        while target.count < 5 { target.append(0) }
        target[index] += deltaDeg
        let ok = await moveJoints(target, speed: 15, acc: 200, radius: -1)
        if let j = await readJoints() { joints = j }
        return ok
    }

    // MARK: - Commands (human units in, radians on the wire)

    /// Clear faults, energise the servos, position mode, ready state. Same sequence the
    /// factory export runs before every program.
    func enable() async -> Bool {
        _ = await command(FC.cleanWar)
        _ = await command(FC.cleanErr)
        guard await command(FC.motionEnable, Data([8, 1])) != nil else { return false }  // 8 = all servos
        guard await command(FC.setMode, Data([0])) != nil else { return false }          // 0 = position mode
        guard await command(FC.setState, Data([0])) != nil else { return false }         // 0 = ready
        try? await Task.sleep(nanoseconds: 500_000_000)
        enabled = true
        return true
    }

    /// Tell the controller what is bolted to the wrist, so it plans correctly.
    func setTcpLoad(mass: Double, centre: [Double]) async -> Bool {
        var p = Data()
        p.appendLE32(Float(mass))
        for i in 0..<3 { p.appendLE32(Float(i < centre.count ? centre[i] : 0)) }
        return await command(FC.setLoad, p) != nil
    }

    func setTcpOffset(_ offset: [Double]) async -> Bool {
        var p = Data()
        for i in 0..<6 {
            let v = i < offset.count ? offset[i] : 0
            p.appendLE32(Float(i < 3 ? v : v * .pi / 180))       // mm, then degrees → radians
        }
        guard await command(FC.setTcpOffset, p) != nil else { return false }
        _ = await command(FC.setState, Data([0]))
        return true
    }

    /// Move all five joints to absolute angles. `radius` < 0 = stop at the point; ≥ 0 = blend
    /// through it (mm). Speed °/s, acc °/s².
    func moveJoints(_ degs: [Double], speed: Double, acc: Double, radius: Double) async -> Bool {
        var p = Data()
        for i in 0..<7 { p.appendLE32(Float((i < degs.count ? degs[i] : 0) * .pi / 180)) }  // 7 slots always
        p.appendLE32(Float(speed * .pi / 180))
        p.appendLE32(Float(acc * .pi / 180))
        if radius >= 0 {
            p.appendLE32(Float(radius))
            return await motion(FC.moveJointB, p)
        } else {
            p.appendLE32(Float(0))                                       // mvtime
            return await motion(FC.moveJoint, p)
        }
    }

    /// Straight-line move of the tool. `pose` = x y z (mm), roll pitch yaw (degrees).
    /// Speed mm/s, acc mm/s².
    func moveLine(_ pose: [Double], speed: Double, acc: Double, radius: Double) async -> Bool {
        var p = Data()
        for i in 0..<6 {
            let v = i < pose.count ? pose[i] : 0
            p.appendLE32(Float(i < 3 ? v : v * .pi / 180))
        }
        p.appendLE32(Float(speed))
        p.appendLE32(Float(acc))
        p.appendLE32(Float(0))                                           // mvtime
        if radius >= 0 {
            p.appendLE32(Float(radius))
            return await motion(FC.moveLineB, p)
        } else {
            return await motion(FC.moveLine, p)
        }
    }

    /// The arm's built-in "go home" (all joints to zero).
    func home(speed: Double, acc: Double) async -> Bool {
        var p = Data()
        p.appendLE32(Float(speed * .pi / 180))
        p.appendLE32(Float(acc * .pi / 180))
        p.appendLE32(Float(0))
        return await motion(FC.moveHome, p)
    }

    /// A pause inside the arm's own queue, so it happens between two moves at the right moment.
    func queuePause(_ seconds: Double) async -> Bool {
        var p = Data()
        p.appendLE32(Float(seconds))
        return await motion(FC.sleep, p)
    }

    /// STOP: state 4. The next `enable()` brings it back.
    func stop() async {
        _ = await command(FC.setState, Data([4]))
        enabled = false
        armState = 4
    }

    // MARK: - Reads

    func getState() async -> Int? {
        guard let d = await command(FC.getState), d.count >= 1 else { return nil }
        return Int(d[0])
    }

    func getError() async -> Int? {
        guard let d = await command(FC.getError), d.count >= 1 else { return nil }
        return Int(d[0])
    }

    /// Commands waiting in the controller's queue. 0 = nothing queued. (16-bit, big-endian.)
    func queuedCommands() async -> Int? {
        guard let d = await command(FC.getCmdNum), d.count >= 2 else { return nil }
        return Int(d[0]) << 8 | Int(d[1])
    }

    /// The program number the rail is signalling on the six wires into the controller's
    /// digital inputs CI1…CI6 (CI1 = lowest bit). 0 = nothing signalled.
    func railSignal() async -> Int? {
        guard let d = await command(FC.getInputs), d.count >= 2 else { return nil }
        let raw = Int(d[0]) << 8 | Int(d[1])
        return (raw >> 1) & 0x3F
    }

    func readJoints() async -> [Double]? {
        guard let d = await command(FC.getJointPos), d.count >= 28 else { return nil }
        return Array(floats(d, count: 7).map { $0 * 180 / .pi }.prefix(5))
    }

    /// x y z (mm), roll pitch yaw (degrees).
    func readTcpPose() async -> [Double]? {
        guard let d = await command(FC.getTcpPose), d.count >= 24 else { return nil }
        let v = floats(d, count: 6)
        return [v[0], v[1], v[2], v[3] * 180 / .pi, v[4] * 180 / .pi, v[5] * 180 / .pi]
    }

    /// What the arm's error code means, in words.
    var faultText: String {
        switch errorCode {
        case 0:       return ""
        case 1:       return "Emergency-stop button pressed"
        case 2:       return "Control-box emergency input triggered"
        case 3:       return "Three-position switch e-stop"
        case 10...17: return "Servo motor error (joint \(errorCode - 9))"
        case 18:      return "Force/torque sensor comms error"
        case 19:      return "End-module comms error"
        case 21:      return "Target unreachable (kinematic error)"
        case 22:      return "Self-collision detected"
        case 23:      return "Joint angle over limit"
        case 24:      return "Speed over limit"
        case 25:      return "Planning error"
        case 28:      return "Motion command over limit"
        case 35:      return "Safety boundary limit"
        default:      return "Error \(errorCode)"
        }
    }

    // MARK: - Wire

    private func floats(_ d: Data, count: Int) -> [Double] {
        (0..<count).map { i in
            let lo = i * 4
            let bits = d.subdata(in: lo..<(lo + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return Double(Float(bitPattern: UInt32(littleEndian: bits)))
        }
    }

    /// A motion command: also refused when the controller says "not ready" (0x10).
    private func motion(_ funcode: UInt8, _ params: Data) async -> Bool {
        guard await command(funcode, params) != nil else { return false }
        return lastStatus & 0x10 == 0
    }

    /// Status byte of the last reply. Bits: 0x08 = command rejected, 0x10 = not ready,
    /// 0x20 = a warning is latched, 0x40 = an error is latched.
    private(set) var lastStatus: UInt8 = 0

    /// One request at a time; the reply stream desyncs if two overlap.
    /// Returns the payload, or nil if the link failed or the controller rejected the command.
    private func command(_ funcode: UInt8, _ params: Data = Data()) async -> Data? {
        guard let conn = connection, connected else { return nil }
        while inflight {
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        inflight = true
        defer { inflight = false }

        tid &+= 1
        var frame = Data()
        frame.appendBE16(tid)
        frame.appendBE16(2)                                 // protocol id = 2
        frame.appendBE16(UInt16(1 + params.count))
        frame.append(funcode)
        frame.append(params)

        do {
            try await send(conn, frame)
            let header = try await recv(conn, 6)
            let len = Int(header[4]) << 8 | Int(header[5])
            let body = try await recv(conn, len)            // [funcode][status][payload]
            guard body.count >= 2 else { return nil }
            lastStatus = body[1]
            if body[1] & 0x08 != 0 { return nil }           // rejected
            return body.count > 2 ? body.subdata(in: 2..<body.count) : Data()
        } catch {
            // A timed-out command leaves the byte stream misaligned, so drop the link rather than
            // risk pairing the next reply with the wrong request. Auto-connect picks it back up.
            disconnect()
            return nil
        }
    }

    private func send(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            })
        }
    }

    private func recv(_ conn: NWConnection, _ n: Int, seconds: Double = 3) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.recvExact(conn, n) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ArmError.timeout
            }
            guard let first = try await group.next() else { throw ArmError.timeout }
            group.cancelAll()
            return first
        }
    }

    private nonisolated func recvExact(_ conn: NWConnection, _ n: Int) async throws -> Data {
        var buf = Data()
        while buf.count < n {
            let chunk: Data = try await withCheckedThrowingContinuation { c in
                conn.receive(minimumIncompleteLength: 1, maximumLength: n - buf.count) { d, _, _, err in
                    if let err { c.resume(throwing: err) } else { c.resume(returning: d ?? Data()) }
                }
            }
            if chunk.isEmpty { throw ArmError.timeout }
            buf.append(chunk)
        }
        return buf
    }
}

private extension Data {
    mutating func appendBE16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func appendLE32(_ f: Float) {
        var bits = f.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &bits) { append(contentsOf: $0) }
    }
}

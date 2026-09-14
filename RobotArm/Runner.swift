import Foundation

/// Runs one program at a time: gets the arm ready, fires the rail, waits for the rail's
/// "go" signal, queues the arm steps, waits for the arm to finish, and reports in one line.
@MainActor
final class Runner: ObservableObject {
    static let shared = Runner()
    private init() {}

    private let arm = ArmLink.shared
    private let rail = RailLink.shared

    @Published private(set) var running = false
    /// True from the moment the arm's steps are handed over (after the rail's cue and any delay)
    /// until the run ends. The booth starts its recording on this, so the clip's first seconds
    /// are the move and not the wait for the wires.
    @Published private(set) var motionStarted = false
    @Published private(set) var status = "Ready" {
        didSet { if status != oldValue { Log.write("status: \(status)") } }
    }

    /// The last time the rail's six-wire cue was seen: which program, and how long after the
    /// trigger was sent (timed from the start of the rail conversation, since the cue can arrive
    /// while the trigger's own writes are still going out). The rig's real sync figure —
    /// measured, not assumed.
    @Published private(set) var lastSignal: (program: Int, latency: Double, at: Date)?

    /// How long to wait for the wires. The rail's longest start delay (program 6) is 9.4 s, and
    /// the wires may come up as late as the movement does.
    static let signalTimeout: Double = 6   // a booth fallback: if the wire edge is missed, do not make the guest wait 15 s

    private var task: Task<Void, Never>?

    // What is bolted to the wrist, exactly as the factory export sets it.
    private let tcpLoadMass = 1.46
    private let tcpLoadCentre = [23.84, 15.44, 26.31]
    private let tcpOffset: [Double] = [0, 0, 120, 0, 0, 0]

    /// The connection we last did the full enable + tool setup on. While the arm stays
    /// connected and ready, later runs skip that and start immediately.
    private var preparedGeneration = -1

    /// Run a whole program (rail + arm).
    func run(_ program: Program) {
        start(name: program.name, railProgram: program.railProgram, armStart: program.armStart,
              armDelay: program.armDelay, steps: program.steps)
    }

    /// Try one step on the arm only (used by "Move arm here" in the step editor).
    func test(_ step: Step) {
        var s = step
        s.pauseAfter = 0
        start(name: "test move", railProgram: nil, armStart: .timer, armDelay: 0, steps: [s])
    }

    /// Fire a rail program on its own and watch the wires — no arm motion at all. This is how
    /// to find out whether the control box signals a code, and how long after the trigger.
    func measureSignal(railProgram n: Int) {
        guard !running else { status = "Already running — press STOP first"; return }
        guard rail.connected else { status = "Rail is not connected"; return }
        guard arm.connected else { status = "Arm is not connected — its inputs are where the wires arrive"; return }
        guard rail.homed == "1" else { status = "Rail is not referenced — tap Home the rail first"; return }
        running = true
        task = Task { @MainActor in
            Log.write("measure: firing rail program \(n), arm still, watching CI1–CI6")
            status = "Measuring the wires for rail program \(n)…"
            let watcher = Task { await self.waitForSignal(n) }
            guard await rail.runProgram(n) else {
                watcher.cancel()
                status = rail.lastError.isEmpty ? "Rail refused program \(n)" : rail.lastError
                running = false
                return
            }
            let seen = await watcher.value
            if !Task.isCancelled {
                if seen, let l = lastSignal, l.program == n {
                    status = String(format: "Rail signalled program %d on the wires %.2f s after the trigger", n, l.latency)
                } else {
                    status = "No signal for program \(n) on the wires in \(Int(Self.signalTimeout)) s — check CI1–CI6"
                }
                running = false
            }
        }
    }

    /// True from STOP until both machines have actually been told to stop.
    private var stopping = false

    /// STOP everything. Always allowed.
    ///
    /// `running` stays true until the stop has finished talking to the rail. Seen on the rig
    /// 2026-09-14: STOP, then Run four seconds later while the stop's own writes (Enable 0,
    /// triggers 0, Manual 0) were still going out to the slow control box — the two
    /// conversations interleaved, the trigger took 15 s, the rail never signalled and the arm
    /// ran on the timer against a still carriage. One conversation with the rail at a time.
    func stop() {
        Log.write("STOP pressed")
        task?.cancel()
        task = nil
        preparedGeneration = -1          // after a stop the arm needs enabling again
        status = "STOPPED"
        motionStarted = false
        guard !stopping else { return }
        stopping = true
        running = true
        Task { @MainActor in
            await arm.stop()
            await rail.stop()
            stopping = false
            running = false
            status = "STOPPED — press Run to go again"
        }
    }

    private func start(name: String, railProgram: Int?, armStart: ArmStart, armDelay: Double, steps: [Step]) {
        guard !running else { status = "Already running — press STOP first"; return }
        guard arm.connected else { status = "Arm is not connected"; return }
        if railProgram != nil, !rail.connected { status = "Rail is not connected"; return }
        guard !steps.isEmpty else { status = "\(name) has no steps"; return }

        running = true
        motionStarted = false
        Log.write("run: “\(name)” rail \(railProgram.map(String.init) ?? "none") start \(armStart.rawValue) delay \(armDelay) steps \(steps.count)")
        task = Task { @MainActor in
            let result = await execute(name: name, railProgram: railProgram, armStart: armStart,
                                       armDelay: armDelay, steps: steps)
            if !Task.isCancelled {
                status = result
                running = false
                motionStarted = false
            }
        }
    }

    /// Returns the final status text.
    private func execute(name: String, railProgram: Int?, armStart: ArmStart, armDelay: Double, steps: [Step]) async -> String {
        // 1. Get the arm ready. Only the slow part (enable + tool setup) is skipped when the arm
        //    is already connected, ready and fault-free from a previous run.
        if let why = await prepareArm() { return why }
        if Task.isCancelled { return "STOPPED" }

        // 2. Fire the rail, then start the arm on its cue.
        //
        // The cue is the six wires: the rail's control box raises the program number on them
        // the way it always has, and the arm goes the moment it sees its number — exactly what
        // the original arm program did. The watcher starts BEFORE the rail is touched, because
        // nobody knows which write makes the PLC raise the wires; a watcher started afterwards
        // would miss the fast case. If the wires never say the number, the arm starts on a
        // timer and the status line says so — a silent fallback is how a rig runs out of step
        // for a whole event without anyone knowing why.
        var fallbackNote = ""
        if let n = railProgram {
            // The control box accepts the trigger and does nothing when the rail is not
            // referenced. Say so here instead of letting a take run against a still carriage.
            guard rail.homed == "1" else {
                return "Rail is not referenced — tap Home the rail on the Programs screen first"
            }
            let watcher: Task<Bool, Never>? = armStart == .signal
                ? Task { await self.waitForSignal(n) }
                : nil
            status = "Starting rail program \(n)…"
            guard await rail.runProgram(n) else {
                watcher?.cancel()
                return rail.lastError.isEmpty ? "Rail refused program \(n)" : rail.lastError
            }
            if let watcher {
                status = "Rail program \(n) started — waiting for its signal on the wires"
                let seen = await watcher.value
                if Task.isCancelled { return "STOPPED" }
                if seen, let l = lastSignal {
                    status = String(format: "Rail signalled %d after %.2f s — arm going", n, l.latency)
                } else {
                    fallbackNote = " (no signal on the wires — arm started on a timer)"
                    status = "No signal on the wires for program \(n) — starting the arm anyway"
                }
            }
            if armDelay > 0 {
                status = "Arm in \(Fmt.num(armDelay)) s"
                try? await Task.sleep(nanoseconds: UInt64(armDelay * 1_000_000_000))
                if Task.isCancelled { return "STOPPED" }
            }
        }

        // 3. Hand every step to the arm. The arm queues them and plays them back to back.
        motionStarted = true
        status = "Running \(name)…"
        var pauseTotal: Double = 0
        for (i, step) in steps.enumerated() {
            let ok: Bool
            switch step.kind {
            case .joint:
                ok = await arm.moveJoints(step.joints, speed: min(step.speed, Limits.maxJointSpeed),
                                          acc: max(step.acc, 1), radius: step.radius)
            case .line:
                ok = await arm.moveLine(step.pose, speed: min(step.speed, Limits.maxLineSpeed),
                                        acc: max(step.acc, 1), radius: step.radius)
            case .home:
                ok = await arm.home(speed: min(step.speed, Limits.maxJointSpeed), acc: max(step.acc, 1))
            case .pause:
                ok = true
            }
            guard ok else {
                await arm.stop()
                await arm.refreshStatus()
                preparedGeneration = -1
                let why = arm.errorCode != 0 ? " — \(arm.faultText)" : ""
                return "Arm rejected step \(i + 1)\(why)"
            }
            if step.pauseAfter > 0 {
                guard await arm.queuePause(step.pauseAfter) else {
                    await arm.stop()
                    preparedGeneration = -1
                    return "Arm rejected the pause after step \(i + 1)"
                }
                pauseTotal += step.pauseAfter
            }
            if Task.isCancelled { return "STOPPED" }
        }

        // 4. Wait until the arm has nothing left to do.
        let started = Date()
        let minimumRun = pauseTotal   // the arm cannot be done before its pauses have elapsed
        var quiet = 0
        while true {
            if Task.isCancelled { return "STOPPED" }
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !arm.connected { preparedGeneration = -1; return "Lost the arm mid-run" }
            if let e = await arm.getError(), e != 0 {
                await arm.refreshStatus()
                preparedGeneration = -1
                return "Arm fault \(e): \(arm.faultText)"
            }
            let st = await arm.getState() ?? 0
            if st >= 4 { preparedGeneration = -1; return "Arm stopped itself (state \(st))" }
            if st == 3 { preparedGeneration = -1; return "Arm is PAUSED on the controller" }
            let queued = await arm.queuedCommands() ?? 0
            let elapsed = Date().timeIntervalSince(started)
            if st == 1 || queued > 0 || elapsed < minimumRun {
                quiet = 0
            } else {
                quiet += 1
                if quiet >= 3 { break }          // 0.6 s of nothing happening
            }
            if elapsed > 15 * 60 { return "Gave up waiting after 15 minutes" }
        }
        await arm.refreshStatus()

        // 5. The rail may still be on its way back — program 14 returns to 0 after the arm has
        //    finished. Done means the whole rig is at rest, so a capture keeps rolling and the
        //    next Run cannot start into a moving carriage.
        if railProgram != nil, rail.connected {
            status = "Arm done — rail finishing…"
            await rail.waitUntilStill()
            if Task.isCancelled { return "STOPPED" }
        }
        return "Done — \(name)" + fallbackNote
    }

    /// Wait for the rail's control box to raise `n` on the six wires. True when it did.
    ///
    /// The cue is an EDGE, not a level. If the wires already read `n` from the previous run
    /// and never change, that is not a cue — it would start the arm before the rail has been
    /// told anything — so the pins must read something other than `n` at some point after
    /// watching began, then `n`.
    private func waitForSignal(_ n: Int) async -> Bool {
        let t0 = Date()
        var initial: Int?
        var seenOther = false
        var unreadable = 0
        while Date().timeIntervalSince(t0) < Self.signalTimeout {
            if Task.isCancelled { return false }
            guard let b = await arm.railSignal() else {
                unreadable += 1
                if unreadable >= 20 {                     // a second of nothing: the link is the problem
                    Log.write("wires: input pins unreadable — arm link problem, not the PLC")
                    return false
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            unreadable = 0
            if initial == nil { initial = b }
            if b != n { seenOther = true }
            if b == n, initial != n || seenOther {
                let latency = Date().timeIntervalSince(t0)
                lastSignal = (n, latency, Date())
                Log.write(String(format: "wires: program %d seen %.2f s after the trigger began (first read %d)", n, latency, initial ?? -1))
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        Log.write("wires: NO signal for program \(n) in \(Int(Self.signalTimeout)) s — pins read \(initial.map(String.init) ?? "nothing") throughout")
        return false
    }

    /// Full enable + tool setup the first time on a connection (or after a stop / fault);
    /// otherwise just confirm the arm is ready. Returns a reason if it is not.
    /// Enable the arm and set its tool params ahead of a run, so the slow first-run cost happens
    /// DURING the countdown instead of after it. Cached by connection generation, so calling this
    /// and then `run()` does the work once. Returns a reason string if the arm could not be readied.
    @discardableResult
    func prewarm() async -> String? { await prepareArm() }

    private func prepareArm() async -> String? {
        let st = await arm.getState() ?? 0
        let err = await arm.getError() ?? 0
        let alreadyReady = preparedGeneration == arm.connectionGeneration && err == 0 && (st == 1 || st == 2)
        if alreadyReady { return nil }

        status = "Enabling arm…"
        guard await arm.enable() else { return "Arm would not enable" }
        _ = await arm.setTcpLoad(mass: tcpLoadMass, centre: tcpLoadCentre)
        _ = await arm.setTcpOffset(tcpOffset)
        try? await Task.sleep(nanoseconds: 300_000_000)
        await arm.refreshStatus()
        if arm.errorCode != 0 { return "Arm fault \(arm.errorCode): \(arm.faultText)" }
        guard arm.armState == 1 || arm.armState == 2 else { return "Arm is not ready (state \(arm.armState))" }
        preparedGeneration = arm.connectionGeneration
        return nil
    }
}

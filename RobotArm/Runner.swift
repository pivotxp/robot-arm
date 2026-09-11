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
    @Published private(set) var status = "Ready"

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
        start(name: program.name, railProgram: program.railProgram,
              armDelay: program.armDelay, steps: program.steps)
    }

    /// Try one step on the arm only (used by "Move arm here" in the step editor).
    func test(_ step: Step) {
        var s = step
        s.pauseAfter = 0
        start(name: "test move", railProgram: nil, armDelay: 0, steps: [s])
    }

    /// STOP everything. Always allowed.
    func stop() {
        task?.cancel()
        task = nil
        running = false
        preparedGeneration = -1          // after a stop the arm needs enabling again
        status = "STOPPED"
        Task { @MainActor in
            await arm.stop()
            await rail.stop()
            status = "STOPPED — press Run to go again"
        }
    }

    private func start(name: String, railProgram: Int?, armDelay: Double, steps: [Step]) {
        guard !running else { status = "Already running — press STOP first"; return }
        guard arm.connected else { status = "Arm is not connected"; return }
        if railProgram != nil, !rail.connected { status = "Rail is not connected"; return }
        guard !steps.isEmpty else { status = "\(name) has no steps"; return }

        running = true
        task = Task { @MainActor in
            let result = await execute(name: name, railProgram: railProgram, armDelay: armDelay, steps: steps)
            if !Task.isCancelled {
                status = result
                running = false
            }
        }
    }

    /// Returns the final status text.
    private func execute(name: String, railProgram: Int?, armDelay: Double, steps: [Step]) async -> String {
        // 1. Get the arm ready. Only the slow part (enable + tool setup) is skipped when the arm
        //    is already connected, ready and fault-free from a previous run.
        if let why = await prepareArm() { return why }
        if Task.isCancelled { return "STOPPED" }

        // 2. Fire the rail. Then start the arm — right away by default. If a program needs the
        //    arm to lag the rail, that is the one "extra seconds" number on the program.
        if let n = railProgram {
            status = "Starting rail program \(n)…"
            guard await rail.runProgram(n) else { return rail.lastError.isEmpty ? "Rail refused program \(n)" : rail.lastError }
            if armDelay > 0 {
                status = "Rail program \(n) started — arm in \(Fmt.num(armDelay)) s"
                try? await Task.sleep(nanoseconds: UInt64(armDelay * 1_000_000_000))
                if Task.isCancelled { return "STOPPED" }
            }
        }

        // 3. Hand every step to the arm. The arm queues them and plays them back to back.
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
        return "Done — \(name)"
    }

    /// Full enable + tool setup the first time on a connection (or after a stop / fault);
    /// otherwise just confirm the arm is ready. Returns a reason if it is not.
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

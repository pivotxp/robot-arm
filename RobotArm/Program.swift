import Foundation

/// What kind of thing one step is.
enum StepKind: String, Codable, CaseIterable, Identifiable {
    case joint   // move all five joints to given angles
    case line    // move the camera in a straight line to an x/y/z position
    case pause   // just wait
    case home    // the arm's built-in "go home" (all joints to zero)

    var id: String { rawValue }
    var label: String {
        switch self {
        case .joint: return "Joint move"
        case .line:  return "Straight line"
        case .pause: return "Pause"
        case .home:  return "Go home"
        }
    }
}

/// One step of a program. All numbers are in human units:
/// joints in degrees, pose in mm and degrees, speed °/s or mm/s, acc °/s² or mm/s², seconds.
struct Step: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: StepKind = .joint
    /// Five joint angles (Pan, Lift, Bend, Tilt, Roll), degrees. Used by `.joint`.
    var joints: [Double] = [0, 0, 0, 0, 0]
    /// x y z (mm), roll pitch yaw (degrees). Used by `.line`.
    var pose: [Double] = [0, 0, 0, 0, 0, 0]
    var speed: Double = 30
    var acc: Double = 500
    /// Blend radius in mm. -1 or 0 = stop exactly at this point; bigger = round the corner.
    var radius: Double = 0
    /// Seconds to wait after this step before the next one.
    var pauseAfter: Double = 0

    private enum CodingKeys: String, CodingKey { case kind, joints, pose, speed, acc, radius, pauseAfter }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(StepKind.self, forKey: .kind) ?? .joint
        if let j = try c.decodeIfPresent([Double].self, forKey: .joints), j.count == 5 { joints = j }
        if let p = try c.decodeIfPresent([Double].self, forKey: .pose), p.count == 6 { pose = p }
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 30
        acc = try c.decodeIfPresent(Double.self, forKey: .acc) ?? 500
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0
        pauseAfter = try c.decodeIfPresent(Double.self, forKey: .pauseAfter) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch kind {
        case .joint: try c.encode(joints, forKey: .joints)
        case .line:  try c.encode(pose, forKey: .pose)
        default: break
        }
        if kind != .pause {
            try c.encode(speed, forKey: .speed)
            try c.encode(acc, forKey: .acc)
            try c.encode(radius, forKey: .radius)
        }
        try c.encode(pauseAfter, forKey: .pauseAfter)
    }

    /// Same settings as another step (ignoring the internal id)?
    func sameSettings(as o: Step) -> Bool {
        kind == o.kind && joints == o.joints && pose == o.pose &&
        speed == o.speed && acc == o.acc && radius == o.radius && pauseAfter == o.pauseAfter
    }

    /// One line describing the step, for lists.
    var summary: String {
        let pause = pauseAfter > 0 ? " · wait \(Fmt.num(pauseAfter)) s" : ""
        switch kind {
        case .joint:
            return "Joints " + joints.map(Fmt.num).joined(separator: ", ") + " · \(Fmt.num(speed))°/s" + pause
        case .line:
            return "Line to " + pose.prefix(3).map(Fmt.num).joined(separator: ", ") + " mm · \(Fmt.num(speed)) mm/s" + pause
        case .pause:
            return "Wait \(Fmt.num(pauseAfter)) s"
        case .home:
            return "Go home · \(Fmt.num(speed))°/s" + pause
        }
    }

    /// Things worth a warning. Never blocks a run; the arm itself refuses what it cannot do.
    var warnings: [String] {
        var out: [String] = []
        if kind == .joint {
            for (i, v) in joints.enumerated() where !Limits.jointRange[i].contains(v) {
                let r = Limits.jointRange[i]
                out.append("\(Limits.jointNames[i]) \(Fmt.num(v))° is outside what the factory programs use (\(Fmt.num(r.lowerBound)) to \(Fmt.num(r.upperBound))).")
            }
            if speed > Limits.maxJointSpeed { out.append("Speed over \(Fmt.num(Limits.maxJointSpeed))°/s will be capped.") }
        }
        if kind == .line, speed > Limits.maxLineSpeed { out.append("Speed over \(Fmt.num(Limits.maxLineSpeed)) mm/s will be capped.") }
        return out
    }
}

/// What tells the arm to go, once the rail program has been fired.
enum ArmStart: String, Codable, CaseIterable, Identifiable {
    /// When the rail's control box raises the program number on the six wires into the arm's
    /// inputs CI1–CI6. This is the cue the original arm program used, so it is the default.
    case signal
    /// A stopwatch from the moment the rail was fired. For when the wires are not connected.
    case timer

    var id: String { rawValue }
    var label: String {
        switch self {
        case .signal: return "When the rail signals (six wires)"
        case .timer:  return "On a timer from the trigger"
        }
    }
}

/// One program: the arm steps plus which rail program to fire.
struct Program: Codable, Identifiable, Equatable {
    var number: Int
    var name: String
    /// Which of the rail's stored programs to start when this runs. nil = leave the rail alone.
    var railProgram: Int?
    /// What starts the arm after the rail is fired. Only matters when `railProgram` is set.
    var armStart: ArmStart = .signal
    /// Extra seconds the arm waits after its start cue before its first move.
    var armDelay: Double = 0
    var note: String = ""
    var steps: [Step] = []

    var id: Int { number }

    private enum CodingKeys: String, CodingKey { case number, name, railProgram, armStart, armDelay, note, steps }

    init(number: Int, name: String, railProgram: Int? = nil, armStart: ArmStart = .signal,
         armDelay: Double = 0, note: String = "", steps: [Step] = []) {
        self.number = number; self.name = name; self.railProgram = railProgram
        self.armStart = armStart; self.armDelay = armDelay; self.note = note; self.steps = steps
    }

    /// Files written before `armStart` existed decode as "signal", which is what they did on the
    /// original rig — the arm program waited for the wires.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Program \(number)"
        railProgram = try c.decodeIfPresent(Int.self, forKey: .railProgram)
        armStart = try c.decodeIfPresent(ArmStart.self, forKey: .armStart) ?? .signal
        armDelay = try c.decodeIfPresent(Double.self, forKey: .armDelay) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
    }

    var subtitle: String {
        var parts = ["\(steps.count) step\(steps.count == 1 ? "" : "s")"]
        if let r = railProgram {
            parts.append(RailCatalog.hasMove(r) ? "rail \(r)" : "rail \(r) (no move stored)")
            parts.append(armStart == .signal ? "on signal" : "on timer")
        } else {
            parts.append("no rail")
        }
        if armDelay > 0 { parts.append("+\(Fmt.num(armDelay)) s") }
        return parts.joined(separator: " · ")
    }
}

/// What the rail's control box actually has stored, code by code.
///
/// The Siemens accepts any ProgramNumber 0–63, but only some of those slots hold a movement.
/// This list comes from running every number on the real rail on 2026-09-10 and watching
/// whether the carriage moved: 37 codes moved it, code 16 did not, nothing above 38 did. Code 0
/// is the rail's own home / stop. It is a fact about the machine as delivered — if the
/// manufacturer adds programs in TIA Portal, update it.
enum RailCatalog {
    static let codes: ClosedRange<Int> = 0...63
    /// Codes the rail acts on. 0 is its home / stop, which is an action even if not a "move".
    static let withMove: Set<Int> = Set([0]).union(Set(1...15)).union(Set(17...38))

    static func hasMove(_ code: Int) -> Bool { withMove.contains(code) }
}

struct FactoryFile: Codable {
    var programs: [Program]
}

/// Ranges taken from the factory programs themselves. Outside = warning, not a block.
enum Limits {
    static let jointNames = ["Pan", "Lift", "Bend", "Tilt", "Roll"]
    static let jointRange: [ClosedRange<Double>] = [
        -182.4...180.0,
        -116.0...117.4,
        -218.3...6.9,
        -96.0...166.2,
        -215.5...165.7,
    ]
    static let maxJointSpeed: Double = 180    // °/s, the fastest any factory program goes
    static let maxLineSpeed: Double = 1000    // mm/s
}

enum Fmt {
    static func num(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

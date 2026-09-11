import SwiftUI

/// A simple side-on drawing of the arm, built from the joint angles. It is a rough picture for
/// feedback, not an exact model: it shows the arm's shape bending as Lift, Bend and Tilt change,
/// and a small dial shows which way Pan is facing. Good enough to see a pose without leaning over
/// the machine.
struct ArmView: View {
    /// Five joint angles in degrees (Pan, Lift, Bend, Tilt, Roll). Empty = draw the parked shape.
    var joints: [Double]

    var body: some View {
        Canvas { ctx, size in
            let j = normalized
            drawArm(ctx: &ctx, size: size, joints: j)
            drawPanDial(ctx: &ctx, size: size, pan: j[0])
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topLeading) {
            Text("Side view")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(6)
        }
    }

    private var normalized: [Double] {
        var j = joints
        while j.count < 5 { j.append(0) }
        return j
    }

    // Link lengths in arbitrary drawing units; auto-scaled to fit.
    private let pillar = 40.0, upperArm = 92.0, foreArm = 78.0, wrist = 34.0

    private func jointPoints(_ j: [Double]) -> [CGPoint] {
        // Vertical plane, y up. Zero pose = straight up.
        let a = j[1] * .pi / 180                 // Lift (shoulder)
        let b = (j[1] + j[2]) * .pi / 180        // + Bend (elbow)
        let c = (j[1] + j[2] + j[3]) * .pi / 180 // + Tilt (wrist)
        var pts = [CGPoint(x: 0, y: 0)]                              // base
        let shoulder = CGPoint(x: 0, y: pillar)
        pts.append(shoulder)
        let elbow = CGPoint(x: shoulder.x + upperArm * sin(a), y: shoulder.y + upperArm * cos(a))
        pts.append(elbow)
        let wristP = CGPoint(x: elbow.x + foreArm * sin(b), y: elbow.y + foreArm * cos(b))
        pts.append(wristP)
        let tool = CGPoint(x: wristP.x + wrist * sin(c), y: wristP.y + wrist * cos(c))
        pts.append(tool)
        return pts
    }

    private func drawArm(ctx: inout GraphicsContext, size: CGSize, joints j: [Double]) {
        let pts = jointPoints(j)
        // Anchor the base at bottom-centre; scale so the arm's reach fits with padding.
        let pad = 30.0
        let reach = pts.map { hypot($0.x, $0.y) }.max()!            // max distance from base
        let scale = min((size.width / 2 - pad) / max(reach, 1),
                        (size.height - 2 * pad) / max(reach, 1))
        let baseScreen = CGPoint(x: size.width / 2, y: size.height - pad)
        func screen(_ p: CGPoint) -> CGPoint {
            CGPoint(x: baseScreen.x + p.x * scale, y: baseScreen.y - p.y * scale)   // y up
        }
        let s = pts.map(screen)

        // Segments.
        var path = Path()
        path.move(to: s[0])
        for p in s.dropFirst() { path.addLine(to: p) }
        ctx.stroke(path, with: .color(Color.accentColor), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))

        // Joints as dots.
        for p in s {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                     with: .color(Color(.systemBackground)))
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                       with: .color(Color.accentColor), lineWidth: 2)
        }
        // Base plate.
        let base = s[0]
        ctx.fill(Path(CGRect(x: base.x - 22, y: base.y - 4, width: 44, height: 8)), with: .color(.secondary))
    }

    private func drawPanDial(ctx: inout GraphicsContext, size: CGSize, pan: Double) {
        let r = 18.0
        let c = CGPoint(x: size.width - r - 14, y: size.height - r - 14)
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                   with: .color(.secondary), lineWidth: 1.5)
        let ang = (pan - 90) * .pi / 180   // 0° points up
        let tip = CGPoint(x: c.x + r * cos(ang), y: c.y + r * sin(ang))
        var needle = Path(); needle.move(to: c); needle.addLine(to: tip)
        ctx.stroke(needle, with: .color(Color.accentColor), lineWidth: 3)
        ctx.draw(Text("Pan").font(.system(size: 9)).foregroundStyle(.secondary),
                 at: CGPoint(x: c.x, y: c.y + r + 8))
    }
}

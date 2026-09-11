import SwiftUI

/// What a guest can choose to capture. Kept from the CanonPivotBot booth so the video-template
/// recipes (which are keyed by action name) port over unchanged.
enum CaptureAction: String, CaseIterable, Identifiable {
    case still, gif, burst, video
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .still: return "STILL"
        case .gif:   return "GIF"
        case .burst: return "BURST"
        case .video: return "VIDEO"
        }
    }

    var systemImage: String {
        switch self {
        case .still: return "camera.fill"
        case .gif:   return "rectangle.stack.fill"
        case .burst: return "square.3.layers.3d.down.right"
        case .video: return "video.fill"
        }
    }

    var enabledKey: String { "pivotbot.\(rawValue).enabled" }
    var programKey: String { "pivotbot.\(rawValue).program" }

    var defaultEnabled: Bool {
        switch self {
        case .still: return false
        case .gif, .burst, .video: return true
        }
    }

    var defaultProgram: Int {
        switch self {
        case .gif:   return 1
        case .burst: return 2
        case .video: return 3
        case .still: return 4
        }
    }
}

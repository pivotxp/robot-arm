import SwiftUI
import UIKit
import CoreText

/// Colour + font palette used by the ported video-template screens. Trimmed from the
/// CanonPivotBot app. The condensed font falls back to a system face if the asset isn't present.
enum Brand {
    static let red          = Color(red: 210/255, green: 10/255, blue: 10/255)
    static let redHi        = Color(red: 232/255, green: 56/255, blue: 56/255)
    static let black        = Color.black
    static let white        = Color.white
    static let ink          = Color(white: 0.12)
    static let inkMuted     = Color(white: 0.42)
    static let canvasTop    = Color(white: 0.985)
    static let canvasBottom = Color(white: 0.93)
    static let deepBlue     = Color(red: 0x11/255, green: 0x36/255, blue: 0x57/255)

    static let condensedBlackName: String = registerCondensedBlack()

    static func condensedBlack(size: CGFloat) -> Font {
        Font.custom(condensedBlackName, size: size)
    }

    private static func registerCondensedBlack() -> String {
        guard let asset = NSDataAsset(name: "UFCSansCondensedBlack"),
              let provider = CGDataProvider(data: asset.data as CFData),
              let cgFont = CGFont(provider),
              let psName = cgFont.postScriptName as String? else {
            return "HelveticaNeue-CondensedBlack"
        }
        _ = CTFontManagerRegisterGraphicsFont(cgFont, nil)
        return psName
    }
}

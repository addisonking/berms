import CoreGraphics
import SwiftUI

enum ShareCardPreset: String, CaseIterable, Codable, Identifiable {
    case story
    case post
    case portrait

    /// Design canvas is 360 points wide; render at this scale for a 1080 px wide export.
    static let renderScale: CGFloat = 3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .story: "Story"
        case .post: "Post"
        case .portrait: "Portrait"
        }
    }

    var detail: String {
        switch self {
        case .story: "1080 × 1920 · Instagram story"
        case .post: "1080 × 1080 · Instagram post"
        case .portrait: "1080 × 1350 · Instagram portrait post"
        }
    }

    var canvasSize: CGSize {
        switch self {
        case .story: CGSize(width: 360, height: 640)
        case .post: CGSize(width: 360, height: 360)
        case .portrait: CGSize(width: 360, height: 450)
        }
    }

    /// Map frame size in points, matched by the snapshot request so the export is pixel exact.
    var mapFrameSize: CGSize {
        switch self {
        case .story: canvasSize
        case .post: CGSize(width: 360, height: 210)
        case .portrait: CGSize(width: 312, height: 190)
        }
    }

    var pixelSize: CGSize {
        CGSize(width: canvasSize.width * Self.renderScale,
               height: canvasSize.height * Self.renderScale)
    }

    var pixelDescription: String {
        "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px"
    }
}

struct ShareCardPalette {
    let background: Color
    let primaryText: Color
    let secondaryText: Color
    let panel: Color
    let scrim: Color
    let watermark: Color

    static func of(_ preset: ShareCardPreset) -> ShareCardPalette {
        switch preset {
        case .story:
            ShareCardPalette(
                background: Color(red: 0.05, green: 0.06, blue: 0.07),
                primaryText: .white,
                secondaryText: .white.opacity(0.72),
                panel: Color(red: 0.05, green: 0.06, blue: 0.07),
                scrim: .black,
                watermark: .white
            )
        case .post:
            ShareCardPalette(
                background: Color(red: 0.05, green: 0.06, blue: 0.07),
                primaryText: .white,
                secondaryText: .white.opacity(0.72),
                panel: Color(red: 0.06, green: 0.07, blue: 0.08),
                scrim: .black,
                watermark: .white
            )
        case .portrait:
            ShareCardPalette(
                background: Color(red: 0.965, green: 0.961, blue: 0.949),
                primaryText: Color(red: 0.08, green: 0.08, blue: 0.09),
                secondaryText: Color(red: 0.43, green: 0.42, blue: 0.41),
                panel: .white,
                scrim: .white,
                watermark: Color(red: 0.28, green: 0.28, blue: 0.28)
            )
        }
    }
}

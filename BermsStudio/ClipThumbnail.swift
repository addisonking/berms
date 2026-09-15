import AVFoundation
import SwiftUI

/// Renders a still frame from a clip so runs can be scanned visually.
struct ClipThumbnail: View {
    let url: URL

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 88, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .task(id: url) {
            image = await Self.thumbnail(for: url)
        }
    }

    private static func thumbnail(for url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 140)
        return try? await generator.image(at: .zero).image
    }
}

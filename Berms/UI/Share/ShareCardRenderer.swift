import Photos
import SwiftUI
import UIKit

enum ShareCardExportError: LocalizedError {
    case encodingFailed
    case writingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .encodingFailed: "The image could not be encoded."
        case .writingFailed(let error): "The image could not be saved. \(error.localizedDescription)"
        }
    }
}

enum ShareCardPhotosError: LocalizedError {
    case readFailed
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .readFailed: "The image could not be read."
        case .notAuthorized: "Berms doesn't have permission to add to Photos. Enable it in Settings."
        }
    }
}

enum ShareCardPhotos {
    static func savePNG(at url: URL) async throws {
        guard let data = try? Data(contentsOf: url) else {
            throw ShareCardPhotosError.readFailed
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ShareCardPhotosError.notAuthorized
        }
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = url.lastPathComponent
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
        }
    }
}

@MainActor
enum ShareCardRenderer {
    static func render(
        content: ShareCardContent,
        configuration: ShareCardConfiguration,
        mapImage: UIImage?
    ) -> UIImage? {
        let canvas = ShareCardCanvas(content: content, configuration: configuration, mapImage: mapImage)
            .frame(
                width: configuration.preset.canvasSize.width,
                height: configuration.preset.canvasSize.height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = ShareCardPreset.renderScale
        renderer.isOpaque = true
        return renderer.uiImage
    }

    static func writePNG(_ image: UIImage, fileName: String) throws -> URL {
        guard let data = image.pngData() else { throw ShareCardExportError.encodingFailed }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ShareCardExportError.writingFailed(error)
        }
        return url
    }

    static func fileName(content: ShareCardContent, preset: ShareCardPreset, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let slug = content.resortName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "Berms-\(slug.isEmpty ? "ride" : slug)-\(formatter.string(from: date))-\(preset.rawValue).png"
    }
}

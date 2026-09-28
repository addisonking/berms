import Foundation

final class RawLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.addis.berms.raw-log", qos: .utility)
    private var handle: FileHandle?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init(url: URL) {
        var directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func append(_ record: RawDiagnosticRecord) {
        guard let encoded = try? encoder.encode(record) else { return }
        var lineData = encoded
        lineData.append(0x0A)
        queue.async { [weak self, lineData] in
            guard let self, let handle = self.handle else { return }
            try? handle.write(contentsOf: lineData)
        }
    }

    func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    func close() {
        queue.sync {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
    }
}

import Foundation

enum RouteCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static func encode(_ points: [RoutePoint]) throws -> Data {
        try encoder.encode(points)
    }

    static func decode(_ data: Data) throws -> [RoutePoint] {
        try decoder.decode([RoutePoint].self, from: data)
    }
}

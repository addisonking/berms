import Foundation

enum RouteCodec {
    static func encode(_ points: [RoutePoint]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(points)
    }

    static func decode(_ data: Data) throws -> [RoutePoint] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode([RoutePoint].self, from: data)
    }
}

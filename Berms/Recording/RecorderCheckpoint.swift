import Foundation

struct RecorderCheckpoint: Codable, Sendable {
    let version: Int
    let points: [TrackSample]
    let jumps: [JumpEvent]

    init(points: [TrackSample], jumps: [JumpEvent] = []) {
        self.version = 1
        self.points = points
        self.jumps = jumps
    }
}

import Foundation

struct RawDiagnosticRecord: Codable, Sendable {
    let kind: String
    let runNumber: Int?
    let trailSequence: [String]?
    let timestamp: Date
    let monotonicSeconds: Double
    let latitude: Double?
    let longitude: Double?
    let gpsAltitude: Double?
    let fusedAltitude: Double?
    let relativeAltitude: Double?
    let pressureKPa: Double?
    let trackMonotonicSeconds: Double?
    let speed: Double?
    let course: Double?
    let horizontalAccuracy: Double?
    let verticalAccuracy: Double?
    let userAccelerationX: Double?
    let userAccelerationY: Double?
    let userAccelerationZ: Double?
    let rotationRateX: Double?
    let rotationRateY: Double?
    let rotationRateZ: Double?
    let gravityX: Double?
    let gravityY: Double?
    let gravityZ: Double?
    let quaternionW: Double?
    let quaternionX: Double?
    let quaternionY: Double?
    let quaternionZ: Double?
    let stationary: Bool?
    let cycling: Bool?
    let automotive: Bool?
    let runEligible: Bool?
    let accepted: Bool?
    let phaseBefore: String?
    let phaseAfter: String?
    let detectorVersion: String?
    let jumpAirtime: Double?
    let jumpTakeoffMonotonicSeconds: Double?
    let jumpLandingMonotonicSeconds: Double?
    let jumpReason: String?
    let detail: String?

    init(
        kind: String, timestamp: Date = .now, monotonicSeconds: Double = ProcessInfo.processInfo.systemUptime,
        runNumber: Int? = nil,
        trailSequence: [String]? = nil,
        latitude: Double? = nil, longitude: Double? = nil, gpsAltitude: Double? = nil,
        fusedAltitude: Double? = nil, relativeAltitude: Double? = nil, pressureKPa: Double? = nil,
        trackMonotonicSeconds: Double? = nil, speed: Double? = nil,
        course: Double? = nil, horizontalAccuracy: Double? = nil, verticalAccuracy: Double? = nil,
        userAccelerationX: Double? = nil, userAccelerationY: Double? = nil, userAccelerationZ: Double? = nil,
        rotationRateX: Double? = nil, rotationRateY: Double? = nil, rotationRateZ: Double? = nil,
        gravityX: Double? = nil, gravityY: Double? = nil, gravityZ: Double? = nil,
        quaternionW: Double? = nil, quaternionX: Double? = nil, quaternionY: Double? = nil,
        quaternionZ: Double? = nil, stationary: Bool? = nil, cycling: Bool? = nil, automotive: Bool? = nil,
        runEligible: Bool? = nil, accepted: Bool? = nil, phaseBefore: String? = nil, phaseAfter: String? = nil,
        detectorVersion: String? = nil, jumpAirtime: Double? = nil,
        jumpTakeoffMonotonicSeconds: Double? = nil, jumpLandingMonotonicSeconds: Double? = nil,
        jumpReason: String? = nil, detail: String? = nil
    ) {
        self.kind = kind
        self.runNumber = runNumber
        self.trailSequence = trailSequence
        self.timestamp = timestamp
        self.monotonicSeconds = monotonicSeconds
        self.latitude = latitude
        self.longitude = longitude
        self.gpsAltitude = gpsAltitude
        self.fusedAltitude = fusedAltitude
        self.relativeAltitude = relativeAltitude
        self.pressureKPa = pressureKPa
        self.trackMonotonicSeconds = trackMonotonicSeconds
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.userAccelerationX = userAccelerationX
        self.userAccelerationY = userAccelerationY
        self.userAccelerationZ = userAccelerationZ
        self.rotationRateX = rotationRateX
        self.rotationRateY = rotationRateY
        self.rotationRateZ = rotationRateZ
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.gravityZ = gravityZ
        self.quaternionW = quaternionW
        self.quaternionX = quaternionX
        self.quaternionY = quaternionY
        self.quaternionZ = quaternionZ
        self.stationary = stationary
        self.cycling = cycling
        self.automotive = automotive
        self.runEligible = runEligible
        self.accepted = accepted
        self.phaseBefore = phaseBefore
        self.phaseAfter = phaseAfter
        self.detectorVersion = detectorVersion
        self.jumpAirtime = jumpAirtime
        self.jumpTakeoffMonotonicSeconds = jumpTakeoffMonotonicSeconds
        self.jumpLandingMonotonicSeconds = jumpLandingMonotonicSeconds
        self.jumpReason = jumpReason
        self.detail = detail
    }
}

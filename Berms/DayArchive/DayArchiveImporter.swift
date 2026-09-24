#if DEBUG

    import Foundation
    import SwiftData

    enum DayArchiveImporter {
        static let supportedVersion = 6

        static func importDay(from url: URL, context: ModelContext) throws -> RideDay {
            let export = try decodeExport(at: url)
            guard export.version == supportedVersion else {
                throw DayArchiveImportError.unsupportedVersion(export.version)
            }
            guard let exportedDay = export.days.first else {
                throw DayArchiveImportError.noDayInArchive
            }
            guard let dayID = UUID(uuidString: exportedDay.id) else {
                throw DayArchiveImportError.fileUnreadable(
                    "The day identifier in the archive is malformed.")
            }
            if try dayExists(withID: dayID, in: context) {
                throw DayArchiveImportError.dayAlreadyExists
            }

            let prepared = try exportedDay.segments.map { try prepare($0) }

            let day = RideDay(startedAt: exportedDay.startedAt)
            day.id = dayID
            day.name = exportedDay.name
            day.notes = exportedDay.notes
            day.activityModeRawValue = exportedDay.activityMode?.rawValue
            day.catalogID = exportedDay.catalogID
            day.endedAt = exportedDay.endedAt

            context.insert(day)
            for preparedSegment in prepared {
                let segment = RideSegment(
                    kind: preparedSegment.kind,
                    startedAt: preparedSegment.startedAt,
                    endedAt: preparedSegment.endedAt,
                    routeData: preparedSegment.routeData,
                    jumps: preparedSegment.jumps)
                segment.id = preparedSegment.id
                segment.distanceMeters = preparedSegment.distanceMeters
                segment.verticalMeters = preparedSegment.verticalMeters
                segment.maximumSpeedMetersPerSecond = preparedSegment.maximumSpeedMetersPerSecond
                segment.day = day
                day.segments.append(segment)
                context.insert(segment)
            }
            day.recalculateTotals()

            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
            return day
        }

        private struct PreparedSegment {
            let id: UUID
            let kind: SegmentKind
            let startedAt: Date
            let endedAt: Date
            let routeData: Data
            let jumps: [JumpEvent]
            let distanceMeters: Double
            let verticalMeters: Double
            let maximumSpeedMetersPerSecond: Double
        }

        private static func prepare(_ segment: BermsDataExport.Segment) throws -> PreparedSegment {
            guard let id = UUID(uuidString: segment.id) else {
                throw DayArchiveImportError.fileUnreadable(
                    "A segment identifier in the archive is malformed.")
            }
            let routeData: Data
            do {
                routeData = try RouteCodec.encode(segment.route)
            } catch {
                throw DayArchiveImportError.fileUnreadable(
                    "A route in the archive couldn't be encoded: \(error.localizedDescription)")
            }
            return PreparedSegment(
                id: id,
                kind: segment.kind,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt,
                routeData: routeData,
                jumps: segment.kind == .run ? makeJumps(segment.jumps, route: segment.route) : [],
                distanceMeters: RouteMetrics.distance(of: segment.route),
                verticalMeters: RouteMetrics.vertical(of: segment.route, kind: segment.kind),
                maximumSpeedMetersPerSecond: RouteMetrics.maximumSpeed(of: segment.route))
        }

        private static func makeJumps(
            _ exported: [BermsDataExport.Jump], route: [RoutePoint]
        ) -> [JumpEvent] {
            exported.map { jump in
                let airtime = max(0, jump.airtimeSeconds)
                return JumpEvent(
                    takeoffTimestamp: jump.takeoffAt,
                    landingTimestamp: jump.landingAt,
                    takeoffMonotonicSeconds: 0,
                    landingMonotonicSeconds: airtime,
                    metrics: metrics(for: jump, airtime: airtime, route: route))
            }
        }

        /// The export stores measured size but not monotonic clocks or
        /// coordinates, so size is kept as-is while positions are interpolated
        /// from the route the same way the recorder measured them.
        private static func metrics(
            for jump: BermsDataExport.Jump, airtime: TimeInterval, route: [RoutePoint]
        ) -> JumpMetrics? {
            if let lengthMeters = jump.lengthMeters,
                let heightMeters = jump.heightMeters,
                let dropMeters = jump.dropMeters,
                let takeoff = coordinate(at: jump.takeoffAt, in: route),
                let landing = coordinate(at: jump.landingAt, in: route)
            {
                return JumpMetrics(
                    takeoffCoordinate: takeoff,
                    landingCoordinate: landing,
                    lengthMeters: lengthMeters,
                    heightMeters: heightMeters,
                    dropMeters: dropMeters)
            }
            return JumpMetrics.resolve(
                takeoffTimestamp: jump.takeoffAt,
                landingTimestamp: jump.landingAt,
                airtime: airtime,
                positions: route)
        }

        private static func coordinate(at date: Date, in route: [RoutePoint]) -> Coordinate? {
            for (start, end) in zip(route, route.dropFirst()) {
                guard date >= start.timestamp, date <= end.timestamp else { continue }
                let interval = end.timestamp.timeIntervalSince(start.timestamp)
                let fraction = interval > 0 ? date.timeIntervalSince(start.timestamp) / interval : 0
                return Coordinate(
                    latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                    longitude: start.longitude + (end.longitude - start.longitude) * fraction)
            }
            return nil
        }

        private static func dayExists(withID id: UUID, in context: ModelContext) throws -> Bool {
            var descriptor = FetchDescriptor<RideDay>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            let existing = try context.fetch(descriptor)
            return !existing.isEmpty
        }

        private static func decodeExport(at url: URL) throws -> BermsDataExport {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw DayArchiveImportError.fileUnreadable(error.localizedDescription)
            }
            do {
                return try exportDecoder().decode(BermsDataExport.self, from: data)
            } catch {
                throw DayArchiveImportError.fileUnreadable(error.localizedDescription)
            }
        }

        /// Matches the fractional ISO8601 dates written by `DayArchive.build`.
        private static func exportDecoder() -> JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let value = try container.decode(String.self)
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
                    throw DecodingError.dataCorruptedError(
                        in: container, debugDescription: "Invalid date \(value)")
                }
                return date
            }
            return decoder
        }
    }

    enum DayArchiveImportError: LocalizedError {
        case fileUnreadable(String)
        case unsupportedVersion(Int)
        case dayAlreadyExists
        case noDayInArchive

        var errorDescription: String? {
            switch self {
            case .fileUnreadable(let detail):
                "Couldn't read the day archive: \(detail)"
            case .unsupportedVersion(let version):
                "This archive uses version \(version); this build imports version \(DayArchiveImporter.supportedVersion)."
            case .dayAlreadyExists:
                "A day with the same identifier is already in your library."
            case .noDayInArchive:
                "The archive doesn't contain a day."
            }
        }
    }

#endif

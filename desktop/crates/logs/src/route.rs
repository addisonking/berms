use berms_rides::RoutePoint;

const EARTH_RADIUS_METERS: f64 = 6_371_000.0;

pub(crate) fn distance_meters(points: &[RoutePoint]) -> f64 {
    points
        .windows(2)
        .map(|pair| haversine(&pair[0], &pair[1]))
        .sum()
}

pub(crate) fn descent_meters(points: &[RoutePoint]) -> f64 {
    points
        .windows(2)
        .map(|pair| (pair[0].altitude - pair[1].altitude).max(0.0))
        .sum()
}

pub(crate) fn ascent_meters(points: &[RoutePoint]) -> f64 {
    points
        .windows(2)
        .map(|pair| (pair[1].altitude - pair[0].altitude).max(0.0))
        .sum()
}

pub(crate) fn maximum_speed(points: &[RoutePoint]) -> f64 {
    points
        .iter()
        .map(|point| point.speed.max(0.0))
        .fold(0.0, f64::max)
}

fn haversine(a: &RoutePoint, b: &RoutePoint) -> f64 {
    let lat1 = a.latitude.to_radians();
    let lat2 = b.latitude.to_radians();
    let delta_lat = (b.latitude - a.latitude).to_radians();
    let delta_lon = (b.longitude - a.longitude).to_radians();

    let h =
        (delta_lat / 2.0).sin().powi(2) + lat1.cos() * lat2.cos() * (delta_lon / 2.0).sin().powi(2);

    2.0 * EARTH_RADIUS_METERS * h.sqrt().asin()
}

#[cfg(test)]
mod tests {
    use super::*;
    use berms_rides::Timestamp;

    fn point(latitude: f64, longitude: f64, altitude: f64, speed: f64) -> RoutePoint {
        RoutePoint::new(latitude, longitude, altitude, speed, Timestamp::UNIX_EPOCH)
    }

    #[test]
    fn sums_haversine_distance() {
        let points = [
            point(41.190, -74.500, 100.0, 0.0),
            point(41.191, -74.500, 100.0, 0.0),
        ];
        let distance = distance_meters(&points);
        assert!((distance - 111.2).abs() < 1.0, "got {distance}");
    }

    #[test]
    fn splits_ascent_and_descent() {
        let points = [
            point(0.0, 0.0, 100.0, 0.0),
            point(0.0, 0.0, 90.0, 0.0),
            point(0.0, 0.0, 95.0, 0.0),
        ];
        assert!((descent_meters(&points) - 10.0).abs() < f64::EPSILON);
        assert!((ascent_meters(&points) - 5.0).abs() < f64::EPSILON);
    }

    #[test]
    fn ignores_unknown_speed() {
        let points = [point(0.0, 0.0, 0.0, -1.0), point(0.0, 0.0, 0.0, 7.5)];
        assert!((maximum_speed(&points) - 7.5).abs() < f64::EPSILON);
    }
}

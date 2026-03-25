import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

class BearingUtils {
  /// Calculates bearing in degrees (0–360) from [from] to [to].
  static double bearingTo(LatLng from, LatLng to) {
    final lat1 = _toRad(from.latitude);
    final lat2 = _toRad(to.latitude);
    final dLon = _toRad(to.longitude - from.longitude);

    final y = math.sin(dLon) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);

    return (_toDeg(math.atan2(y, x)) + 360) % 360;
  }

  /// Returns the shortest signed angle from [currentHeading] to [targetBearing].
  /// Positive = clockwise (turn right), Negative = counter-clockwise (turn left).
  static double relativeAngle(double currentHeading, double targetBearing) {
    double diff = (targetBearing - currentHeading + 360) % 360;
    if (diff > 180) diff -= 360;
    return diff;
  }

  /// Converts meters to average walking steps (avg stride ~0.76 m).
  static int metersToSteps(double meters) => (meters / 0.76).round();

  /// Converts meters to a human-friendly spoken string.
  static String metersToSpoken(double meters) {
    if (meters < 10) return 'a few steps';
    if (meters < 50) return '${metersToSteps(meters)} steps';
    if (meters < 200) {
      return '${metersToSteps(meters)} steps (about ${meters.round()} metres)';
    }
    return '${(meters / 1000).toStringAsFixed(1)} kilometres';
  }

  /// Distance between two lat/lng points in metres (haversine).
  static double distanceBetween(LatLng a, LatLng b) {
    const R = 6371000.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final sinDLat = math.sin(dLat / 2);
    final sinDLon = math.sin(dLon / 2);
    final h =
        sinDLat * sinDLat +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            sinDLon *
            sinDLon;
    return 2 * R * math.asin(math.sqrt(h));
  }

  /// Returns the bearing along the nearest polyline segment to [position].
  /// Aligns the compass cone with the actual path direction rather than
  /// pointing toward a distant step end point.
  ///
  /// Finds the nearest segment by checking the midpoint of each segment,
  /// then returns the bearing from that segment's start → end.
  static double bearingAlongRoute(LatLng position, List<LatLng> polyline) {
    if (polyline.length < 2) return 0;

    double minDist = double.infinity;
    int nearestIndex = 0;

    for (int i = 0; i < polyline.length - 1; i++) {
      // Use segment midpoint for nearest-segment search
      final mid = LatLng(
        (polyline[i].latitude + polyline[i + 1].latitude) / 2,
        (polyline[i].longitude + polyline[i + 1].longitude) / 2,
      );
      final d = distanceBetween(position, mid);
      if (d < minDist) {
        minDist = d;
        nearestIndex = i;
      }
    }

    return bearingTo(polyline[nearestIndex], polyline[nearestIndex + 1]);
  }

  static double _toRad(double deg) => deg * math.pi / 180;
  static double _toDeg(double rad) => rad * 180 / math.pi;
}

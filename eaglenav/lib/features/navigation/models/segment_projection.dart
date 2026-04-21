import 'package:latlong2/latlong.dart' as ll;

class SegmentProjection {
  final double distanceMeters;
  final ll.LatLng nearestPoint;

  const SegmentProjection({
    required this.distanceMeters,
    required this.nearestPoint,
  });
}

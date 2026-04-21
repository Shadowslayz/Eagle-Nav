import 'package:latlong2/latlong.dart' as ll;

class RouteProjection {
  final double distanceMeters;
  final ll.LatLng nearestPoint;

  const RouteProjection({
    required this.distanceMeters,
    required this.nearestPoint,
  });
}

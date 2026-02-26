import 'dart:math' show pow;
import 'package:latlong2/latlong.dart' as ll;

/// Decode polyline with precision 6 for Valhalla default
List<ll.LatLng> decodePolyline(String encoded, {int precision = 6}) {
  int index = 0, lat = 0, lng = 0;
  final List<ll.LatLng> coords = [];
  final scale = pow(10, precision).toDouble();

  while (index < encoded.length) {
    int b, result = 0, shift = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << (shift * 5);
      shift++;
    } while (b >= 0x20);
    final dlat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
    lat += dlat;

    result = 0;
    shift = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << (shift * 5);
      shift++;
    } while (b >= 0x20);
    final dlng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
    lng += dlng;
    coords.add(ll.LatLng(lat / scale, lng / scale));
  }

  return coords;
}

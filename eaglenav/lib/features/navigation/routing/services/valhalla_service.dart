import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart' as ll;
import '../../utils/polyline_decoder.dart';
import 'package:flutter/foundation.dart';

/// Fetch a Valhalla route and return decoded polyline6 points for flutter_map.
Future<List<ll.LatLng>> getValhallaRoutePolyline6({
  required String valhallaBaseUrl,
  required ll.LatLng origin,
  required ll.LatLng destination,
  String costing = "pedestrian",
}) async {
  print('Starting Valhalla request');
  print(' Base URL: $valhallaBaseUrl');

  final uri = Uri.parse('$valhallaBaseUrl/route');
  print('Full URI: $uri');

  final body = {
    "locations": [
      {"lat": origin.latitude, "lon": origin.longitude},
      {"lat": destination.latitude, "lon": destination.longitude},
    ],
    "costing": costing, // assuming "pedestrian"
    "costing_options": {
      "pedestrian": {
        // Heavily penalize alleys, service roads, and loading docks
        "alley_factor": 10.0,
        // Heavily penalize walking through parking lots and driveways
        "driveway_factor": 10.0,
        // Avoid dirt/gravel tracks which lack clear tactile boundaries
        "use_tracks": 0.0,
        // Force paved surfaces only (better for cane usage)
        "exclude_unpaved": true,
        // Prefer sidewalks and dedicated walkways
        "walkway_factor": 0.5,
        "sidewalk_factor": 0.5,
        // add these to block tunnels/underground paths
        "tunnel_factor": 50.0, // heavily penalize tunnels
        "use_hills": 0.0, // avoid steep inclines
      },
    },
    "directions_type": {"units": "meters", "language": "en-US"},
    "shape_format": "polyline6",
  };

  print('📤 Request body: ${jsonEncode(body)}');

  try {
    final resp = await http.post(
      uri,
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(body),
    );

    print('Response status: ${resp.statusCode}');
    print('Response body: ${resp.body}');

    if (resp.statusCode != 200) {
      print('Non-200 status code!');
      return [];
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    print('Response keys: ${data.keys.toList()}');

    if (!data.containsKey('trip')) {
      print('No "trip" key in response!');
      return [];
    }

    print('Trip keys: ${data['trip'].keys.toList()}');

    if (!data['trip'].containsKey('legs')) {
      print('No "legs" key in trip!');
      return [];
    }

    final legs = data['trip']['legs'] as List;
    print('Number of legs: ${legs.length}');

    if (legs.isEmpty) {
      print('Legs array is empty!');
      return [];
    }

    print('First leg keys: ${legs[0].keys.toList()}');

    final encoded = data['trip']['legs'][0]['shape'] as String;
    print('Encoded polyline: ${encoded.substring(0, 50)}...');
    print('Encoded length: ${encoded.length}');

    final decoded = await compute(decodePolyline, encoded);

    print('✨ Decoded ${decoded.length} points');

    if (decoded.isNotEmpty) {
      print('First point: ${decoded.first}');
      print('Last point: ${decoded.last}');
    }

    return decoded;
  } catch (e, stackTrace) {
    print('Error: $e');
    print('Stack trace: $stackTrace');
    return [];
  }
}

// ADD THESE NEW CLASSES AND FUNCTION BELOW:

/// Represents a single navigation instruction/maneuver
class NavigationStep {
  final String instruction;
  final ll.LatLng location;
  final ll.LatLng endLocation;
  final int maneuverType;
  final String type;
  final int? turnDegree;
  final double distanceMeters;
  final String? streetName;
  final String? nextStreetName;

  NavigationStep({
    required this.instruction,
    required this.location,
    required this.endLocation,
    required this.maneuverType,
    required this.type,
    this.turnDegree,
    required this.distanceMeters,
    this.streetName,
    this.nextStreetName,
  });

  String getHapticKind() {
    if (type.contains('arrive')) return 'ARRIVE';
    if (type.contains('depart') || type.contains('start')) return 'START';

    if (turnDegree != null) {
      if (turnDegree! > 315 || turnDegree! < 45) return 'CONTINUE_AHEAD';
      if (turnDegree! >= 45 && turnDegree! < 135) return 'TURN_RIGHT';
      if (turnDegree! >= 225 && turnDegree! < 315) return 'TURN_LEFT';
    }

    if (type.toLowerCase().contains('left')) return 'TURN_LEFT';
    if (type.toLowerCase().contains('right')) return 'TURN_RIGHT';
    if (type.toLowerCase().contains('straight')) return 'CONTINUE_AHEAD';

    return 'CONTINUE_AHEAD';
  }

  String getTTSInstruction() {
    return instruction;
  }

  String? getTurnDirection() {
    switch (maneuverType) {
      case 9:
        return 'bear slightly right';
      case 10:
        return 'turn right';
      case 11:
        return 'turn sharp right';
      case 12:
        return 'make a U-turn right';
      case 13:
        return 'make a U-turn left';
      case 14:
        return 'turn sharp left';
      case 15:
        return 'turn left';
      case 16:
        return 'bear slightly left';
      case 24:
        return 'enter the roundabout';
      case 4:
        return 'arrive at your destination';
      default:
        return null; // continue/straight — no turn to announce
    }
  }
}

/// Complete route with polyline and navigation steps
class ValhallaRoute {
  final List<ll.LatLng> polyline;
  final List<NavigationStep> steps;
  final double totalDistanceMeters;
  final double totalTimeSeconds;

  ValhallaRoute({
    required this.polyline,
    required this.steps,
    required this.totalDistanceMeters,
    required this.totalTimeSeconds,
  });
}

/// Fetch route WITH turn-by-turn directions
Future<ValhallaRoute?> getValhallaRoute({
  required String valhallaBaseUrl,
  required ll.LatLng origin,
  required ll.LatLng destination,
  String costing = "pedestrian",
}) async {
  print('Starting Valhalla request with directions');

  final uri = Uri.parse('$valhallaBaseUrl/route');

  // KEY CHANGE: Remove "directions_type": "none" to get maneuvers
  final body = {
    "locations": [
      {"lat": origin.latitude, "lon": origin.longitude},
      {"lat": destination.latitude, "lon": destination.longitude},
    ],
    "costing": costing,
    "directions_options": {"units": "meters", "language": "en-US"},
    "shape_format": "polyline6",
  };

  try {
    final resp = await http.post(
      uri,
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(body),
    );

    if (resp.statusCode != 200) {
      print('Error: ${resp.statusCode} - ${resp.body}');
      return null;
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;

    if (!data.containsKey('trip') || !data['trip'].containsKey('legs')) {
      print('Invalid response structure');
      return null;
    }

    final legs = data['trip']['legs'] as List;
    if (legs.isEmpty) return null;

    final firstLeg = legs[0] as Map<String, dynamic>;

    // Decode polyline
    final encoded = firstLeg['shape'] as String;
    final polyline = await compute(decodePolyline, encoded);

    // Extract maneuvers (turn-by-turn directions)
    final maneuvers = firstLeg['maneuvers'] as List? ?? [];
    final steps = <NavigationStep>[];

    for (var entry in maneuvers.asMap().entries) {
      final i = entry.key;
      final m = entry.value as Map<String, dynamic>;

      final beginIndex = m['begin_shape_index'] as int? ?? 0;
      final endIndex = m['end_shape_index'] as int? ?? 0;

      /* final shapeIndex = m['begin_shape_index'] as int? ?? 0;
      final location = shapeIndex < polyline.length
          ? polyline[shapeIndex]
          : polyline.first; */
      final location = beginIndex < polyline.length
          ? polyline[beginIndex]
          : polyline.first;

      final endLocation = endIndex < polyline.length
          ? polyline[endIndex]
          : polyline.last;

      // peek at next maneuver for nextStreetName
      final nextM = i + 1 < maneuvers.length
          ? maneuvers[i + 1] as Map<String, dynamic>
          : null;

      final rawType = m['type'] as int? ?? 0;

      steps.add(
        NavigationStep(
          instruction: m['instruction'] as String? ?? 'Continue',
          location: location,
          endLocation: endLocation,
          maneuverType: rawType,
          type: _getManeuverType(m['type'] as int? ?? 0),
          turnDegree: m['turn_degree'] as int?,
          distanceMeters: ((m['length'] as num?)?.toDouble() ?? 0.0) * 1000,
          streetName: _getStreetName(m),
          nextStreetName: nextM != null ? _getStreetName(nextM) : null,
        ),
      );
    }

    final summary = firstLeg['summary'] as Map<String, dynamic>? ?? {};

    print('Route: ${steps.length} steps, ${polyline.length} points');

    return ValhallaRoute(
      polyline: polyline,
      steps: steps,
      totalDistanceMeters:
          ((summary['length'] as num?)?.toDouble() ?? 0.0) * 1000,
      totalTimeSeconds: (summary['time'] as num?)?.toDouble() ?? 0.0,
    );
  } catch (e, stackTrace) {
    print('Error: $e');
    print('Stack trace: $stackTrace');
    return null;
  }
}

String _getManeuverType(int type) {
  switch (type) {
    case 0:
      return 'none';
    case 1:
      return 'start';
    case 2:
      return 'start_right';
    case 3:
      return 'start_left';
    case 4:
      return 'destination';
    case 5:
      return 'destination_right';
    case 6:
      return 'destination_left';
    case 7:
      return 'becomes';
    case 8:
      return 'continue';
    case 9:
      return 'slight_right';
    case 10:
      return 'right';
    case 11:
      return 'sharp_right';
    case 12:
      return 'uturn_right';
    case 13:
      return 'uturn_left';
    case 14:
      return 'sharp_left';
    case 15:
      return 'left';
    case 16:
      return 'slight_left';
    case 17:
      return 'ramp_straight';
    case 18:
      return 'ramp_right';
    case 19:
      return 'ramp_left';
    case 20:
      return 'exit_right';
    case 21:
      return 'exit_left';
    case 22:
      return 'stay_straight';
    case 23:
      return 'stay_right';
    case 24:
      return 'stay_left';
    case 25:
      return 'merge';
    case 26:
      return 'roundabout_enter';
    case 27:
      return 'roundabout_exit';
    case 28:
      return 'ferry_enter';
    case 29:
      return 'ferry_exit';
    default:
      return 'continue';
  }
}

String? _getStreetName(Map<String, dynamic> maneuver) {
  final streetNames = maneuver['street_names'] as List?;
  if (streetNames != null && streetNames.isNotEmpty) {
    return streetNames[0] as String;
  }
  return null;
}

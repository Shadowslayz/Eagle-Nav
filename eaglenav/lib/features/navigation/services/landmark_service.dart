import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import '../utils/bearing_utils.dart';

/// A single landmark result with distance and spoken relative direction.
class NearbyLandmark {
  final String name;
  final double distanceMeters;
  final String relativeDirection; // e.g. "to your left", "ahead of you"

  const NearbyLandmark({
    required this.name,
    required this.distanceMeters,
    required this.relativeDirection,
  });
}

/// Loads buildings.json from assets and answers spatial queries about
/// nearby landmarks relative to the user's current position and heading.
///
/// Only buildings with speakable: true are considered.
class LandmarkService {
  static const String _assetPath = 'assets/data/buildings.json';
  static const double _nearbyRadiusMeters = 50.0;
  static const int _maxResults = 2;

  List<_Building>? _buildings;

  /// Call once at app startup or before first use.
  Future<void> load() async {
    if (_buildings != null) return;
    final raw = await rootBundle.loadString(_assetPath);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final features = json['features'] as List<dynamic>;

    _buildings = features
        .map((f) => f as Map<String, dynamic>)
        .where((f) {
          final props = f['properties'] as Map<String, dynamic>;
          return props['speakable'] == true;
        })
        .map((f) {
          final props = f['properties'] as Map<String, dynamic>;
          final center = props['center'] as List<dynamic>;
          return _Building(
            name: props['name'] as String,
            location: LatLng(
              (center[0] as num).toDouble(),
              (center[1] as num).toDouble(),
            ),
          );
        })
        .toList();
  }

  /// Returns up to [_maxResults] landmarks within [_nearbyRadiusMeters],
  /// sorted by distance, with relative direction based on [userHeading].
  List<NearbyLandmark> findNearby(LatLng position, double userHeading) {
    if (_buildings == null) return [];

    const dist = Distance();
    final results = <NearbyLandmark>[];

    for (final building in _buildings!) {
      final meters = dist.as(LengthUnit.Meter, position, building.location);
      if (meters > _nearbyRadiusMeters) continue;

      final bearingToLandmark = BearingUtils.bearingTo(
        position,
        building.location,
      );
      final relAngle = BearingUtils.relativeAngle(
        userHeading,
        bearingToLandmark,
      );
      final direction = _relativeDirection(relAngle);
      final steps = BearingUtils.metersToSteps(meters);

      results.add(
        NearbyLandmark(
          name: building.name,
          distanceMeters: meters,
          relativeDirection: '$direction, about $steps steps away',
        ),
      );
    }

    results.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return results.take(_maxResults).toList();
  }

  /// Converts a relative angle (degrees, positive = right) into a
  /// plain-language direction the user can act on without a compass.
  String _relativeDirection(double relAngle) {
    final abs = relAngle.abs();
    final side = relAngle >= 0 ? 'right' : 'left';

    if (abs <= 22.5) return 'ahead of you';
    if (abs <= 67.5) return 'to your front $side';
    if (abs <= 112.5) return 'to your $side';
    if (abs <= 157.5) return 'to your rear $side';
    return 'behind you';
  }
}

class _Building {
  final String name;
  final LatLng location;
  const _Building({required this.name, required this.location});
}

/* /// Data models for campus buildings and their entrances.
///
/// [Building] represents a campus structure parsed from a GeoJSON Feature,
/// holding its identity, coordinates, and a list of [BuildingEntrance] objects.
/// The [mainEntrance] getter prioritizes accessible entrances. [BuildingEntrance]
/// represents a single entry point with coordinates, accessibility info, and
/// a human-readable description. */
import 'package:latlong2/latlong.dart' as ll;

class Building {
  final String id;
  final String name;
  final String kind;
  final bool speakable;
  final double latitude;
  final double longitude;
  final List<BuildingEntrance> entrances;

  Building({
    required this.id,
    required this.name,
    required this.kind,
    required this.speakable,
    required this.latitude,
    required this.longitude,
    required this.entrances,
  });

  // Factory constructor to create Building from GeoJSON Feature
  factory Building.fromGeoJson(Map<String, dynamic> feature) {
    final properties = feature['properties'] as Map<String, dynamic>;
    final geometry = feature['geometry'] as Map<String, dynamic>;
    final coordinates = geometry['coordinates'] as List<dynamic>;

    // Parse entrances
    final entrancesList = properties['entrances'] as List<dynamic>? ?? [];
    final entrances = entrancesList
        .map((e) => BuildingEntrance.fromJson(e as Map<String, dynamic>))
        .toList();

    return Building(
      id: properties['id'] as String,
      name: properties['name'] as String,
      kind: properties['kind'] as String,
      speakable: properties['speakable'] as bool? ?? false,
      latitude: (coordinates[0] as num).toDouble(),
      longitude: (coordinates[1] as num).toDouble(),
      entrances: entrances,
    );
  }

  /// Returns the entrance closest to [userPosition].
  /// Falls back to mainEntrance if no position is available.
  BuildingEntrance? nearestEntrance(double userLat, double userLon) {
    if (entrances.isEmpty) return null;

    const distance = ll.Distance();
    final userPos = ll.LatLng(userLat, userLon);

    BuildingEntrance? nearest;
    double minDist = double.infinity;

    for (final entrance in entrances) {
      final d = distance.as(
        ll.LengthUnit.Meter,
        userPos,
        ll.LatLng(entrance.latitude, entrance.longitude),
      );
      if (d < minDist) {
        minDist = d;
        nearest = entrance;
      }
    }

    return nearest ?? mainEntrance;
  }

  // Get the main entrance (first accessible one, or first one)
  BuildingEntrance? get mainEntrance {
    if (entrances.isEmpty) return null;

    // Prefer accessible entrances
    final accessible = entrances.where((e) => e.accessible).toList();
    if (accessible.isNotEmpty) return accessible.first;

    return entrances.first;
  }

  @override
  String toString() => name;
}

class BuildingEntrance {
  final String id;
  final double latitude;
  final double longitude;
  final bool accessible;
  final bool speakable;
  final String description;

  BuildingEntrance({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.accessible,
    required this.speakable,
    required this.description,
  });

  factory BuildingEntrance.fromJson(Map<String, dynamic> json) {
    final coords = json['coordinates'] as List<dynamic>;
    return BuildingEntrance(
      id: json['id'] as String,
      latitude: (coords[0] as num).toDouble(),
      longitude: (coords[1] as num).toDouble(),
      accessible: json['accessible'] as bool? ?? false,
      speakable: json['speakable'] as bool? ?? false,
      description: json['description'] as String? ?? '',
    );
  }
}

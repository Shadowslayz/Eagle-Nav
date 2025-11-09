// lib/io/geojson_loader.dart

import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import '../models/poi.dart';

/// Loads campus POIs (entrances, landmarks, etc.) from a GeoJSON asset.
///
/// 🔹 Expected input format:
/// - A **FeatureCollection** of **Point** features only
/// - Each feature has:
///     geometry: { "type": "Point", "coordinates": [lon, lat] }  // WGS84
///     properties: {
///       "id": "entr_king_a",            // unique + stable (string)
///       "name": "King Hall — Entrance A",
///       "kind": "entrance|landmark|elevator|stairs|restroom",
///       "accessible": true              // optional; default false
///     }
///
/// 🔹 Coordinate order is **[longitude, latitude]** (GeoJSON standard).
/// 🔹 The default asset path must be listed in `pubspec.yaml` under `assets:`.
///
/// Example snippet:
/// ```json
/// {
///   "type": "FeatureCollection",
///   "features": [
///     {
///       "type": "Feature",
///       "properties": {
///         "id": "entr_king_a",
///         "name": "King Hall — Entrance A",
///         "kind": "entrance",
///         "accessible": true
///       },
///       "geometry": { "type": "Point", "coordinates": [-118.168001, 34.066201] }
///     }
///   ]
/// }
/// ```
class GeoJsonLoader {
  /// Default place we load points from. Keep this synced with your assets.
  static const String kDefaultAssetPath = 'assets/data/points.geojson';

  /// Reads the GeoJSON file at [assetPath] and returns a list of [Poi]s.
  ///
  /// - Non-Point features (e.g., LineString/Polygon) are **ignored** here.
  ///   If you later add campus path networks, keep them in a separate
  ///   `paths.geojson` and write a dedicated loader for those.
  /// - Unknown or missing fields fall back to safe defaults (e.g., `name` to
  ///   "Unnamed", `accessible` to false).
  static Future<List<Poi>> loadPoints([
    String assetPath = kDefaultAssetPath,
  ]) async {
    // Load the asset as text; throws if the asset path is wrong or missing.
    final txt = await rootBundle.loadString(assetPath);

    // Parse as a JSON object (we expect a FeatureCollection).
    final Map<String, dynamic> data = jsonDecode(txt) as Map<String, dynamic>;

    // Defensive: tolerate missing/empty 'features'.
    final features = (data['features'] as List?) ?? const [];
    final List<Poi> pois = [];

    for (final f in features) {
      // Each feature should be a Map<String, dynamic>
      final map = (f as Map).cast<String, dynamic>();

      // Geometry must be a Point with [lon, lat].
      final geom = (map['geometry'] as Map).cast<String, dynamic>();
      if (geom['type'] != 'Point') continue; // skip non-Point features

      // Properties are optional; we cast and apply defaults below.
      final props = (map['properties'] as Map? ?? const {})
          .cast<String, dynamic>();

      // GeoJSON coordinates are [lon, lat] (NOT [lat, lon]).
      final coords = (geom['coordinates'] as List).cast<num>();
      if (coords.length < 2) continue; // skip malformed coordinates

      pois.add(
        Poi(
          // Prefer a stable unique id. Fall back to 'name' if 'id' is missing.
          id: (props['id'] ?? props['name'] ?? '').toString(),
          // Human-friendly name; fallback avoids nulls in UI.
          name: (props['name'] ?? 'Unnamed').toString(),
          // Controlled vocabulary helps downstream logic and icons.
          kind: (props['kind'] ?? 'landmark').toString(),
          // Convert num → double for models.
          lon: coords[0].toDouble(),
          lat: coords[1].toDouble(),
          // Accessibility flag (e.g., entrance ramps/elevators).
          accessible: (props['accessible'] ?? false) == true,
        ),
      );
    }

    return pois;
  }
}

/* Service for loading and searching campus buildings from a GeoJSON asset file.
 Parses a GeoJSON FeatureCollection, filters for building features, and
 maps them to [Building] model objects. Results are cached in memory after
 the first load to avoid redundant asset reads. Exposes methods to search
 buildings by name or ID, retrieve all buildings, and manually clear the cache. */

import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/building_model.dart';

class BuildingSearchService {
  List<Building>? _cachedBuildings;

  /// Load buildings from GeoJSON file
  Future<List<Building>> loadBuildings() async {
    // Return cached data if available
    if (_cachedBuildings != null) {
      return _cachedBuildings!;
    }

    try {
      // Load JSON file from assets
      final String jsonString = await rootBundle.loadString(
        'assets/data/buildings.json',
      );

      // Parse JSON
      final dynamic jsonData = json.decode(jsonString);

      List<Building> buildings = [];

      // Handle GeoJSON FeatureCollection format
      if (jsonData is Map<String, dynamic>) {
        final String? type = jsonData['type'] as String?;

        if (type == 'FeatureCollection') {
          final List<dynamic>? features =
              jsonData['features'] as List<dynamic>?;

          if (features != null) {
            buildings = features
                .where((feature) {
                  // Only include building features
                  final props = feature['properties'] as Map<String, dynamic>?;
                  return props?['kind'] == 'building';
                })
                .map(
                  (feature) =>
                      Building.fromGeoJson(feature as Map<String, dynamic>),
                )
                .toList();
          }
        }
      }

      // Cache the results
      _cachedBuildings = buildings;

      return buildings;
    } catch (e) {
      throw Exception('Failed to load buildings: $e');
    }
  }

  /// Search buildings by query
  Future<List<Building>> searchBuildings(String query) async {
    if (query.isEmpty) {
      return [];
    }

    final buildings = await loadBuildings();
    final lowerQuery = query.toLowerCase();

    return buildings.where((building) {
      return building.name.toLowerCase().contains(lowerQuery) ||
          building.id.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// Get all buildings
  Future<List<Building>> getAllBuildings() async {
    return await loadBuildings();
  }

  /// Clear cache (useful for testing or refresh)
  void clearCache() {
    _cachedBuildings = null;
  }
}

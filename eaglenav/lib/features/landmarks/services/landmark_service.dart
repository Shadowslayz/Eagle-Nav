import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import '../model/landmark.dart';

class LandmarkService {
  final List<Landmark> _landmarks = [];

  // Path to GeoJSON asset
  final String path = 'assets/data/landmarks.geojson';

  /// Read-only access to landmarks in memory
  List<Landmark> get landmarks => List.unmodifiable(_landmarks);

  /// Load landmark coordinate points into memory
  Future<void> loadLandmarks() async {
    final data = await rootBundle.loadString(path);
    final jsonResult = json.decode(data);

    final List features = jsonResult['features'];

    _landmarks.clear();

    for (final f in features) {
      final coords = f['geometry']['coordinates'];
      final props = f['properties'];

      _landmarks.add(
        Landmark(
          id: props['id'],
          name: props['name'],
          kind: props['kind'],
          latitude: coords[0],
          longitude: coords[1],
          accessible: props['accessible'] ?? false,
          speakable: props['speakable'] ?? false,
        ),
      );
      print(_landmarks[0]); // check if landmarks are loaded
    }
  }
}

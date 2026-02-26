class Landmark {
  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final String kind;
  final bool accessible;
  final bool speakable;

  Landmark({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.kind,
    this.accessible = false,
    this.speakable = true,
  });
  factory Landmark.fromGeoJson(Map<String, dynamic> json) {
    final coords = json['geometry']['coordinates'];

    return Landmark(
      id: json['properties']['id'],

      name: json['properties']['name'],

      kind: json['properties']['kind'],

      speakable: json['properties']['speakable'] ?? false,

      accessible: json['properties']['accessible'] ?? false,

      latitude: coords[0],

      longitude: coords[1],
    );
  }
}

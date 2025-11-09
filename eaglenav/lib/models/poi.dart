// Not in use yet --
class Poi {
  final String id, name, kind;
  final double lat, lon;
  final bool accessible;
  Poi({
    required this.id,
    required this.name,
    required this.kind,
    required this.lat,
    required this.lon,
    this.accessible = false,
  });
}

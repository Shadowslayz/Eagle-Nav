import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;

class FlutterMapWithTilt extends StatefulWidget {
  final ll.LatLng? userLocation;
  final double zoom;
  final double heading;

  const FlutterMapWithTilt({
    super.key,
    this.userLocation,
    this.zoom = 16.0,
    this.heading = 0.0,
  });

  @override
  State<FlutterMapWithTilt> createState() => _FlutterMapWithTiltState();
}

class _FlutterMapWithTiltState extends State<FlutterMapWithTilt> {
  final MapController _mapController = MapController();
  final double _currentTilt = 0.5; // tilt in radians, adjust as needed

  void _recenterMap() {
    if (widget.userLocation != null) {
      _mapController.move(widget.userLocation!, widget.zoom);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Transform(
          alignment: Alignment.center,

          // Stops Flutter from warping gestures through the 3D matrix.
          // The map will now pan and zoom perfectly smoothly.
          transformHitTests: false,

          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.001)
            ..rotateX(_currentTilt),
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: widget.userLocation ?? const ll.LatLng(0, 0),
              initialZoom: widget.zoom,
              // Fixed: 'rotation' is now 'initialRotation'
              initialRotation: widget.heading,
              // Fixed: 'interactiveFlags' moved to InteractionOptions
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                // Recommended: Add your app's package name to comply with OSM policies
                userAgentPackageName: 'com.example.app',
              ),
              if (widget.userLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: widget.userLocation!,
                      width: 40,
                      height: 40,
                      // Fixed: 'builder' is now 'child'
                      child: const Icon(
                        Icons.my_location,
                        color: Colors.blue,
                        size: 30,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        Positioned(
          bottom: 20,
          right: 20,
          child: FloatingActionButton(
            onPressed: _recenterMap,
            child: const Icon(Icons.my_location),
          ),
        ),
      ],
    );
  }
}

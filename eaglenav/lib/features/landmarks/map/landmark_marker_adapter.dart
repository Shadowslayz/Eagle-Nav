// return landmark marker for display

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../model/landmark.dart';

List<Marker> buildLandmarkMarkers(List<Landmark> landmarks) {
  return landmarks.map((landmark) {
    return Marker(
      point: ll.LatLng(landmark.latitude, landmark.longitude),
      width: 20,
      height: 20,
      child: Tooltip(
        message: landmark.name,
        child: Icon(
          Icons.place,
          color: landmark.kind == 'entrance' ? Colors.green : Colors.orange,
          size: 16,
        ),
      ),
    );
  }).toList();
}

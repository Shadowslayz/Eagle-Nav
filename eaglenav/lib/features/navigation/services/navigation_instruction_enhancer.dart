import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import '../domain/entities/enhanced_intruction.dart';
import '../utils/bearing_utils.dart';
import 'compass_service.dart';

class NavigationInstructionEnhancer {
  final CompassService _compass;

  NavigationInstructionEnhancer(this._compass);

  EnhancedInstruction enhance({
    required String valhallaInstruction,
    required int maneuverType,
    required double distanceMeters,
    required LatLng stepEndLocation,
    required LatLng currentLocation,
    required List<LatLng> routePolyline,
    required String streetName,
    String? nextStreetName,
    String? roundaboutExitCount,
  }) {
    debugPrint('maneuverType: $maneuverType — $valhallaInstruction');

    final bool isStartOrContinue =
        maneuverType == 1 ||
        maneuverType == 2 ||
        maneuverType == 3 ||
        maneuverType == 7 ||
        maneuverType == 8 ||
        maneuverType == 22;

    final incomingBearing = routePolyline.length >= 2
        ? BearingUtils.bearingAlongRoute(currentLocation, routePolyline)
        : _compass.currentHeading;

    final targetBearing = isStartOrContinue && routePolyline.length >= 2
        ? incomingBearing
        : BearingUtils.bearingTo(currentLocation, stepEndLocation);

    final relAngle = isStartOrContinue
        ? BearingUtils.relativeAngle(_compass.currentHeading, targetBearing)
        : BearingUtils.relativeAngle(incomingBearing, targetBearing);

    final cardinal = CompassService.cardinalFromBearing(targetBearing);
    final steps = BearingUtils.metersToSteps(distanceMeters);
    final distanceSpoken = BearingUtils.metersToSpoken(distanceMeters);
    final name = streetName.isNotEmpty ? streetName : 'the path';

    return _buildInstruction(
      maneuverType: maneuverType,
      relAngle: relAngle,
      targetBearing: targetBearing,
      cardinal: cardinal,
      distanceMeters: distanceMeters,
      distanceSpoken: distanceSpoken,
      steps: steps,
      name: name,
      nextName: nextStreetName,
      valhallaFallback: valhallaInstruction,
    );
  }

  EnhancedInstruction _buildInstruction({
    required int maneuverType,
    required double relAngle,
    required double targetBearing,
    required String cardinal,
    required double distanceMeters,
    required String distanceSpoken,
    required int steps,
    required String name,
    String? nextName,
    required String valhallaFallback,
  }) {
    final absAngle = relAngle.abs();
    final String turnPhrase = _turnPhrase(relAngle);

    switch (maneuverType) {
      // ── START ────────────────────────────────────────────
      case 1:
      case 2:
      case 3:
        final facing = _facingQuality(absAngle);
        return EnhancedInstruction(
          spokenText: facing == 'good'
              ? 'You are facing the right direction. '
                    'Align your body with the phone and walk forward on $name for $distanceSpoken, about $steps steps.'
              : 'Starting orientation: $turnPhrase to align. ',
          displayText: name != 'the path'
              ? 'Walk forward on $name'
              : 'Walk forward',
          targetBearing: targetBearing,
          distanceMeters: distanceMeters,
          requiresOrientationCheck: facing != 'good',
        );

      // ── DESTINATION ──────────────────────────────────────
      // ── ARRIVAL ──────────────────────────────────────────
      // Use the live compass bearing to tell the user which way to face
      // to find the door, rather than Valhalla's path-relative left/right
      // (which assumes the user is still oriented along the final segment).
      case 4:
      case 5:
      case 6:
        final doorDirection = _arrivalDirection(relAngle);
        return EnhancedInstruction(
          spokenText:
              'You have arrived at the entrance. '
              'The door should be $doorDirection.',
          displayText: 'Arrived at entrance',
          targetBearing: targetBearing,
          distanceMeters: 0,
        );

      // ── BECOMES (path changes name) ──────────────────────
      case 7:
        return EnhancedInstruction(
          spokenText:
              'Continue onto ${nextName ?? name} '
              'for $distanceSpoken, that is $steps steps.',
          displayText: 'Continue onto ${nextName ?? name}',
          targetBearing: targetBearing,
          distanceMeters: distanceMeters,
        );

      // ── CONTINUE STRAIGHT ────────────────────────────────
      case 8:
      case 22:
        return EnhancedInstruction(
          spokenText:
              'Continue straight on $name for $distanceSpoken, '
              'that is $steps steps.',
          displayText: 'Continue on $name',
          targetBearing: targetBearing,
          distanceMeters: distanceMeters,
        );

      // ── SLIGHT RIGHT ─────────────────────────────────────
      case 9:
        return EnhancedInstruction(
          spokenText:
              'In $distanceSpoken, bear slightly right '
              'onto ${nextName ?? name}.',
          displayText: 'Slight right onto ${nextName ?? name}',
          targetBearing: targetBearing,
          distanceMeters: distanceMeters,
          requiresOrientationCheck: false,
        );

      // ── RIGHT ────────────────────────────────────────────
      case 10:
        if (distanceMeters > 40) {
          return EnhancedInstruction(
            spokenText:
                'Walk forward on $name for $distanceSpoken, that is $steps steps.',
            displayText: 'Turn right onto ${nextName ?? name}',
            targetBearing: targetBearing,
            distanceMeters: distanceMeters,
            requiresOrientationCheck: false,
          );
        }
        return EnhancedInstruction(
          spokenText: 'Turn right onto ${nextName ?? name}.',
          displayText: 'Turn right onto ${nextName ?? name}',
          targetBearing: targetBearing,
          distanceMeters: distanceMeters,
          requiresOrientationCheck: false,
        );

      // ── SHARP RIGHT ──────────────────────────────────────
      case 11:
        return EnhancedInstruction(
          spokenText:
              'In $distanceSpoken, make a sharp right turn '
              'onto ${nextName ?? name}.',
          displayText: 'Sharp right onto ${nextName ?? name}',
          targetBearing: targetBearing,
          distanceMeters: distanceMeters,
          requiresOrientationCheck: false,
        );

      // ── SHARP LEFT ───────────────────────────────────────
      case 14:
        return EnhancedInstruction(
          spokenText:
              'In $distanceSpoken, make a sharp left turn '
              'onto ${nextName ?? name}.',
          displayText: 'Sharp left onto ${nextName ?? name}',
          targetBearing: targetBearing,
          distanceMeters: distanceMeters,
          requiresOrientationCheck: false,
        );

      // ── LEFT ─────────────────────────────────────────────
      case 15:
        if (distanceMeters > 40) {
          return EnhancedInstruction(
            spokenText:
                'Walk forward on $name for $distanceSpoken, that is $steps steps.',
            displayText: 'Turn left onto ${nextName ?? name}',
            targetBearing: targetBearing,
            distanceMeters: distanceMeters,
            requiresOrientationCheck: false,
          );
        }
        return EnhancedInstruction(
          spokenText: 'Turn left onto ${nextName ?? name}.',
          displayText: 'Turn left onto ${nextName ?? name}',
          targetBearing: targetBearing,
          distanceMeters: distanceMeters,
          requiresOrientationCheck: false,
        );

      // ── SLIGHT LEFT ──────────────────────────────────────
      case 16:
        return EnhancedInstruction(
          spokenText:
              'In $distanceSpoken, bear slightly left '
              'onto ${nextName ?? name}.',
          displayText: 'Slight left onto ${nextName ?? name}',
          targetBearing: targetBearing,
          distanceMeters: distanceMeters,
          requiresOrientationCheck: false,
        );

      // ── ELEVATOR ─────────────────────────────────────────
      case 33:
        return EnhancedInstruction(
          spokenText: 'In $distanceSpoken, take the elevator.',
          displayText: 'Take elevator',
          targetBearing: targetBearing,
          distanceMeters: distanceMeters,
        );

      // ── STEPS UP ─────────────────────────────────────────
      case 34:
        return EnhancedInstruction(
          spokenText: 'In $distanceSpoken, go up the steps for $steps steps.',
          displayText: 'Steps up',
          targetBearing: targetBearing,
          distanceMeters: distanceMeters,
        );

      // ── STEPS DOWN ───────────────────────────────────────
      case 35:
        return EnhancedInstruction(
          spokenText: 'In $distanceSpoken, go down the steps for $steps steps.',
          displayText: 'Steps down',
          targetBearing: targetBearing,
          distanceMeters: distanceMeters,
        );

      // ── FALLBACK ─────────────────────────────────────────
      default:
        return EnhancedInstruction(
          spokenText: 'Continue for $distanceSpoken, that is $steps steps.',
          displayText: 'Continue',
          targetBearing: targetBearing,
          distanceMeters: distanceMeters,
        );
    }
  }

  String _facingQuality(double absAngle) {
    if (absAngle < 15) return 'good';
    if (absAngle < 45) return 'close';
    return 'off';
  }

  String _turnPhrase(double relAngle) {
    final abs = relAngle.abs();
    final dir = relAngle >= 0 ? 'right' : 'left';
    if (abs < 10) return 'Go straight ahead';
    if (abs < 30) return 'Slightly to the $dir';
    if (abs < 60) return 'Turn $dir';
    if (abs < 120) return 'Turn $dir';
    if (abs < 160) return 'Sharp turn to the $dir';
    return 'Turn completely around';
  }

  /// Converts a relative angle (degrees, positive = right of user heading)
  /// into a plain-language direction the user can act on without sight.
  /// Mirrors LandmarkService's phrasing so the "arrived" cue and the
  /// double-tap landmark cue speak the same directional vocabulary.
  String _arrivalDirection(double relAngle) {
    final abs = relAngle.abs();
    final side = relAngle >= 0 ? 'right' : 'left';

    if (abs <= 22.5) return 'directly in front of you';
    if (abs <= 67.5) return 'to your front $side';
    if (abs <= 112.5) return 'to your $side';
    if (abs <= 157.5) return 'to your rear $side';
    return 'behind you';
  }
}

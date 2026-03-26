class EnhancedInstruction {
  final String spokenText; // Full TTS string
  final String displayText; // Short UI label
  final double targetBearing; // Compass heading user should face
  final double distanceMeters;
  final bool
  requiresOrientationCheck; // Should we wait until user faces right way?

  const EnhancedInstruction({
    required this.spokenText,
    required this.displayText,
    required this.targetBearing,
    required this.distanceMeters,
    this.requiresOrientationCheck = false,
  });
}

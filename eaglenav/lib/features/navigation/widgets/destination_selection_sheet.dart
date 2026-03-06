import 'package:flutter/material.dart';

/// ─── DestinationSheet ────────────────────────────────────────────────────────
///
/// Shown when a destination is selected but navigation has not started.
/// Phase: NavigationPhase.destinationSelected
///
/// Receives:
///   buildingName      → name of the selected building for display
/// TODO: only UI widget for the selection of building
/// walking distance icon, directions button with icon and start nav button with icon, gps coords)
/// ─────────────────────────────────────────────────────────────────────────────

class DestinationSelectionSheet extends StatelessWidget {
  final String destinationName;

  final VoidCallback onLoad;
  final VoidCallback onCancel;
  final VoidCallback onStart;

  const DestinationSelectionSheet({
    // Data to receive
    required this.destinationName,
    required this.onLoad,
    required this.onStart,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              destinationName,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text("Walking distance: -- mins"),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onCancel,
                    child: const Text("Cancel"),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                    ),
                    onPressed: onStart,
                    child: const Text(
                      "Navigate",
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

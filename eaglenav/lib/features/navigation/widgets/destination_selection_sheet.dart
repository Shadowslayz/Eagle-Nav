import 'package:flutter/material.dart';


class DestinationSelectionSheet extends StatelessWidget {
  final String destinationName;
  final bool isNavigating; 
  // flag to toggle button state

  final VoidCallback onLoad;
  final VoidCallback onCancel;
  final VoidCallback onStart;

  const DestinationSelectionSheet({
    // Data to receive
    required this.destinationName,
    required this.onLoad,
    required this.onStart,
    required this.onCancel,
    this.isNavigating = false, 
    // default to false
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
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text("Walking distance: -- mins"),
            const SizedBox(height: 16),
            Row(
              children: [
                // only show cancel if we aren't navigating
                if (!isNavigating) ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onCancel,
                      child: const Text("Cancel"),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                //main action button (Navigate / End Navigation)
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isNavigating ? Colors.red : Colors.blue,
                      
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: onStart,
                    child: Text(
                      isNavigating ? "End Navigation" : "Navigate",
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
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

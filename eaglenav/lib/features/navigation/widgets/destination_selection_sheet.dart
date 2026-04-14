import 'package:flutter/material.dart';

class DestinationSelectionSheet extends StatelessWidget {
  final String destinationName;
  final bool isNavigating;
  final VoidCallback onLoad;
  final VoidCallback onCancel;
  final VoidCallback onStart;

  const DestinationSelectionSheet({
    super.key,
    required this.destinationName,
    required this.onLoad,
    required this.onStart,
    required this.onCancel,
    this.isNavigating = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header strip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: const BoxDecoration(
              color: Color(0xFF1A1A1A),
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFC9A227).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.location_on, color: Color(0xFFC9A227), size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Destination',
                        style: TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        destinationName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (!isNavigating)
                  GestureDetector(
                    onTap: onCancel,
                    child: const Icon(Icons.close, color: Colors.white54, size: 20),
                  ),
              ],
            ),
          ),

          // Walking time row
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Row(
              children: [
                const Icon(Icons.directions_walk, size: 18, color: Colors.black45),
                const SizedBox(width: 6),
                const Text(
                  'Walking distance: -- mins',
                  style: TextStyle(color: Colors.black54, fontSize: 13),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4F4F4),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.accessible, size: 13, color: Colors.black54),
                      SizedBox(width: 4),
                      Text('Accessible', style: TextStyle(fontSize: 11, color: Colors.black54)),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Row(
              children: [
                if (!isNavigating) ...[
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF1A1A1A),
                        side: const BorderSide(color: Color(0xFFDDDDDD)),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: onCancel,
                      child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  flex: isNavigating ? 1 : 2,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isNavigating ? Colors.red.shade700 : const Color(0xFF1A1A1A),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    icon: Icon(
                      isNavigating ? Icons.stop : Icons.navigation,
                      size: 18,
                    ),
                    label: Text(
                      isNavigating ? 'End Navigation' : 'Navigate',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    onPressed: onStart,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

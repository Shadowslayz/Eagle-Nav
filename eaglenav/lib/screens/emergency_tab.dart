import 'package:flutter/material.dart';

class EmergencyTab extends StatelessWidget {
  const EmergencyTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Semantics(
          label: 'Emergency button. Tap to contact campus security.',
          button: true,
          child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          ),
          icon: const Icon(Icons.warning, color: Colors.white),
          label: const Text(
            "Contact Security",
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Emergency tapped")),
            );
          },
        ),
        ),
      ),
    );
  }
}
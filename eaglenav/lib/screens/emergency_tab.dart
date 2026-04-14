import 'package:flutter/material.dart';

class EmergencyTab extends StatelessWidget {
  const EmergencyTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              const Icon(Icons.shield, color: Color(0xFFC9A227), size: 64),
              const SizedBox(height: 20),
              const Text(
                'Emergency',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Cal State LA Campus Safety',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 48),

              // Emergency call button
              Semantics(
                label: 'Emergency button. Tap to contact campus security.',
                button: true,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 4,
                  ),
                  icon: const Icon(Icons.phone, size: 28, semanticLabel: 'Call'),
                  label: const Text(
                    'Call Campus Security',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Calling (323) 343-3700...'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 20),

              // Non-emergency info box
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white.withOpacity(0.1)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Campus Safety Numbers',
                      style: TextStyle(
                        color: Color(0xFFC9A227),
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _InfoRow(icon: Icons.local_police, label: 'Campus Police', value: '(323) 343-3700'),
                    const SizedBox(height: 8),
                    _InfoRow(icon: Icons.medical_services, label: 'Health Center', value: '(323) 343-3300'),
                    const SizedBox(height: 8),
                    _InfoRow(icon: Icons.support_agent, label: 'Crisis Line', value: '(800) 854-7771'),
                  ],
                ),
              ),

              const Spacer(),

              Text(
                'In a life-threatening emergency, always call 911 first.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.4),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Colors.white54, size: 18),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
        const Spacer(),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

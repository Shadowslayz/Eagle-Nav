import 'package:flutter/material.dart';
import '../services/tts_service.dart';
import '../main.dart';

class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key});

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  bool voiceGuidance = true;
  bool highContrast = false;
  bool audioHaptics = true;
  bool rumbleHaptics = false;
  bool aroundPeople = true;
  String colorBlindMode = 'None';
  double colorBlindIntensity = 0.5;
  bool announceObstacles = true;
  bool announceLandmarks = true;
  bool announcePeople = false;
  bool avoidStairs = true;
  bool wheelchairAccessibleRoutes = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F4F4),
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionCard(
            icon: Icons.display_settings,
            title: 'Display',
            children: [
              _SettingSwitch(
                title: 'High Contrast Mode',
                subtitle: 'Increases visibility for low vision',
                value: highContrast,
                onChanged: (v) => setState(() => highContrast = v),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: DropdownButtonFormField<String>(
                  value: colorBlindMode,
                  decoration: InputDecoration(
                    labelText: 'Color Blind Mode',
                    labelStyle: const TextStyle(color: Colors.black54),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: csulGold),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'None', child: Text('None')),
                    DropdownMenuItem(value: 'Protanopia', child: Text('Protanopia (Red-Blind)')),
                    DropdownMenuItem(value: 'Protanomaly', child: Text('Protanomaly (Weak Red)')),
                    DropdownMenuItem(value: 'Deuteranopia', child: Text('Deuteranopia (Green-Blind)')),
                    DropdownMenuItem(value: 'Deuteranomaly', child: Text('Deuteranomaly (Weak Green)')),
                    DropdownMenuItem(value: 'Tritanopia', child: Text('Tritanopia (Blue-Blind)')),
                    DropdownMenuItem(value: 'Tritanomaly', child: Text('Tritanomaly (Weak Blue)')),
                    DropdownMenuItem(value: 'Achromatopsia', child: Text('Achromatopsia (No Color)')),
                  ],
                  onChanged: (v) { if (v != null) setState(() => colorBlindMode = v); },
                ),
              ),
              if (colorBlindMode != 'None')
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Intensity: ${(colorBlindIntensity * 100).round()}%',
                        style: const TextStyle(fontSize: 14, color: Colors.black54),
                      ),
                      Slider(
                        value: colorBlindIntensity,
                        onChanged: (v) => setState(() => colorBlindIntensity = v),
                        min: 0.0,
                        max: 1.0,
                        divisions: 10,
                      ),
                    ],
                  ),
                ),
            ],
          ),

          const SizedBox(height: 12),

          _SectionCard(
            icon: Icons.route,
            title: 'Navigation',
            children: [
              _SettingSwitch(
                title: 'Avoid Stairs',
                subtitle: 'Route around staircases',
                value: avoidStairs,
                onChanged: (v) => setState(() => avoidStairs = v),
              ),
              const Divider(height: 1),
              _SettingSwitch(
                title: 'Wheelchair Accessible Routes',
                subtitle: 'Prioritize accessible paths',
                value: wheelchairAccessibleRoutes,
                onChanged: (v) => setState(() => wheelchairAccessibleRoutes = v),
              ),
              const Divider(height: 1),
              _SettingSwitch(
                title: 'Navigate Around People',
                subtitle: 'Avoid crowds when generating routes',
                value: aroundPeople,
                onChanged: (v) => setState(() => aroundPeople = v),
              ),
            ],
          ),

          const SizedBox(height: 12),

          _SectionCard(
            icon: Icons.record_voice_over,
            title: 'Voice & Announcements',
            children: [
              _SettingSwitch(
                title: 'Enable Voice Guidance',
                subtitle: 'Read turn-by-turn directions aloud',
                value: voiceGuidance,
                onChanged: (v) => setState(() => voiceGuidance = v),
              ),
              const Divider(height: 1),
              _SettingSwitch(
                title: 'Announce Obstacles',
                subtitle: 'Alert when objects are detected nearby',
                value: announceObstacles,
                onChanged: (v) => setState(() => announceObstacles = v),
              ),
              const Divider(height: 1),
              _SettingSwitch(
                title: 'Announce Landmarks',
                subtitle: 'Call out nearby campus landmarks',
                value: announceLandmarks,
                onChanged: (v) => setState(() => announceLandmarks = v),
              ),
              const Divider(height: 1),
              _SettingSwitch(
                title: 'Announce Nearby People',
                subtitle: 'Alert when people are detected',
                value: announcePeople,
                onChanged: (v) => setState(() => announcePeople = v),
              ),
            ],
          ),

          const SizedBox(height: 12),

          _SectionCard(
            icon: Icons.vibration,
            title: 'Haptic Feedback',
            children: [
              _SettingSwitch(
                title: 'Audio Haptics',
                value: audioHaptics,
                onChanged: (v) => setState(() => audioHaptics = v),
              ),
              const Divider(height: 1),
              _SettingSwitch(
                title: 'Rumble Haptics',
                value: rumbleHaptics,
                onChanged: (v) => setState(() => rumbleHaptics = v),
              ),
            ],
          ),

          const SizedBox(height: 24),

          ElevatedButton.icon(
            onPressed: () async {
              await initTts();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Settings saved')),
                );
              }
            },
            icon: const Icon(Icons.check),
            label: const Text('Save Settings'),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;

  const _SectionCard({required this.icon, required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Icon(icon, color: csulGold, size: 20),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A1A),
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ...children,
        ],
      ),
    );
  }
}

class _SettingSwitch extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingSwitch({
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(fontSize: 15)),
      subtitle: subtitle != null
          ? Text(subtitle!, style: const TextStyle(fontSize: 12, color: Colors.black45))
          : null,
      value: value,
      onChanged: onChanged,
      dense: true,
    );
  }
}

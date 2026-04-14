import 'package:flutter/material.dart';
import 'package:eaglenav/features/navigation/presentation/navigation_screen.dart';
import 'favorites_tab.dart';
import 'events_screen.dart';
import 'profile_tab.dart';
import 'emergency_tab.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;

  static const List<Widget> _pages = [
    NavigationScreen(),
    FavoritesTab(),
    EventsScreen(),
    ProfileTab(),
    EmergencyTab(),
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_selectedIndex],
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: _onItemTapped,
          backgroundColor: const Color(0xFF1A1A1A),
          indicatorColor: const Color(0xFFC9A227),
          height: 68,
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const TextStyle(
                color: Color(0xFFC9A227),
                fontSize: 11,
                fontWeight: FontWeight.bold,
              );
            }
            return const TextStyle(
              color: Colors.white54,
              fontSize: 11,
            );
          }),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined, color: Colors.white54),
              selectedIcon: Icon(Icons.home, color: Colors.black),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.star_border, color: Colors.white54),
              selectedIcon: Icon(Icons.star, color: Colors.black),
              label: 'Favorites',
            ),
            NavigationDestination(
              icon: Icon(Icons.event_outlined, color: Colors.white54),
              selectedIcon: Icon(Icons.event, color: Colors.black),
              label: 'Events',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline, color: Colors.white54),
              selectedIcon: Icon(Icons.person, color: Colors.black),
              label: 'Profile',
            ),
            NavigationDestination(
              icon: Icon(Icons.shield_outlined, color: Colors.white54),
              selectedIcon: Icon(Icons.shield, color: Colors.black),
              label: 'Emergency',
            ),
          ],
        ),
    );
  }
}
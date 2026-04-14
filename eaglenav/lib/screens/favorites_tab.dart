import 'package:flutter/material.dart';
import '../main.dart';

class FavoritesTab extends StatelessWidget {
  const FavoritesTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F4F4),
      appBar: AppBar(
        title: const Text('Favorites'),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: csulaDark,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.star, color: csulGold, size: 52),
            ),
            const SizedBox(height: 24),
            const Text(
              'No favorites yet',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A1A),
              ),
            ),
            const SizedBox(height: 10),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 48),
              child: Text(
                'Save buildings and locations here for quick access while navigating campus.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.black54,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 32),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: csulaDark,
                side: const BorderSide(color: csulGold, width: 2),
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.explore_outlined),
              label: const Text(
                'Explore Map',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
  }
}

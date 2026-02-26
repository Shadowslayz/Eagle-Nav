/* A search bar widget for finding and selecting campus buildings.
/
/ Queries [BuildingSearchService] on each keystroke and displays a live
/ dropdown of matching results by building name or ID. Selecting a result
/ fills the search field, dismisses the dropdown, and fires the
/ [onBuildingSelected] callback. Includes a mic button placeholder for
/ future voice search support. */

import 'package:flutter/material.dart';
import '../models/building_model.dart';
import '../services/building_search_service.dart';

class BuildingSearchBar extends StatefulWidget {
  final Function(Building)? onBuildingSelected;

  const BuildingSearchBar({super.key, this.onBuildingSelected});

  @override
  State<BuildingSearchBar> createState() => _BuildingSearchBarState();
}

class _BuildingSearchBarState extends State<BuildingSearchBar> {
  final BuildingSearchService _searchService = BuildingSearchService();
  final TextEditingController _controller = TextEditingController();
  List<Building> _suggestions = [];
  bool _isLoading = false;
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    if (query.isEmpty) {
      setState(() {
        _suggestions = [];
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final results = await _searchService.searchBuildings(query);
      setState(() {
        _suggestions = results;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Search error: $e');
      setState(() {
        _suggestions = [];
        _isLoading = false;
      });
    }
  }

  void _onBuildingSelected(Building building) {
    _controller.text = building.name;
    _focusNode.unfocus();
    setState(() {
      _suggestions = [];
    });

    // Call the callback if provided
    widget.onBuildingSelected?.call(building);

    // Show selected building info
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Selected: ${building.name}'),
          action: SnackBarAction(
            label: 'Navigate',
            onPressed: () {
              debugPrint(
                'Navigate to: ${building.name} at (${building.latitude}, ${building.longitude})',
              );
            },
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: Image.asset(
                  'assets/images/DarkSimplifiedEagleIcon.png',
                  height: 28,
                  width: 28,
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  decoration: const InputDecoration(
                    hintText: 'Search destination...',
                    border: InputBorder.none,
                  ),
                  onChanged: (query) {
                    _performSearch(query);
                  },
                ),
              ),
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.mic, color: Colors.amber),
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Voice search tapped")),
                    );
                  },
                ),
            ],
          ),
        ),
        // Suggestions dropdown
        if (_suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _suggestions.length,
              itemBuilder: (context, index) {
                final building = _suggestions[index];
                return ListTile(
                  leading: const Icon(Icons.location_on, color: Colors.amber),
                  title: Text(building.name),
                  subtitle: Text(
                    '${building.entrances.length} entrance${building.entrances.length != 1 ? 's' : ''}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onTap: () => _onBuildingSelected(building),
                );
              },
            ),
          ),
      ],
    );
  }
}

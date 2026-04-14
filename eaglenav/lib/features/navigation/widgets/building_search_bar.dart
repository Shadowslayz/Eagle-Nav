import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
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
  final FocusNode _focusNode = FocusNode();
  final SpeechToText _speech = SpeechToText();

  List<Building> _suggestions = [];
  bool _isLoading = false;
  bool _isListening = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _speech.stop();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    if (query.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }

    setState(() => _isLoading = true);

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

  Future<void> _startListening() async {
    final available = await _speech.initialize(
      onError: (_) => setState(() => _isListening = false),
    );

    if (!available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Speech recognition not available')),
        );
      }
      return;
    }

    setState(() => _isListening = true);

    _speech.listen(
      onResult: (result) {
        final text = result.recognizedWords;
        _controller.text = text;
        _performSearch(text);
        if (result.finalResult) {
          setState(() => _isListening = false);
        }
      },
      listenFor: const Duration(seconds: 10),
      pauseFor: const Duration(seconds: 2),
      localeId: 'en_US',
    );
  }

  Future<void> _stopListening() async {
    await _speech.stop();
    setState(() => _isListening = false);
  }

  void _onBuildingSelected(Building building) {
    _controller.text = building.name;
    _focusNode.unfocus();
    setState(() => _suggestions = []);
    widget.onBuildingSelected?.call(building);
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
              Semantics(
                label: 'Eagle Nav logo',
                image: true,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: Image.asset(
                    'assets/images/DarkSimplifiedEagleIcon.png',
                    height: 28,
                    width: 28,
                  ),
                ),
              ),
              Expanded(
                child: Semantics(
                  label: 'Search destination',
                  textField: true,
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    decoration: const InputDecoration(
                      hintText: 'Search destination...',
                      border: InputBorder.none,
                    ),
                    onChanged: _performSearch,
                  ),
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
                Semantics(
                  label: _isListening ? 'Stop voice search' : 'Voice search',
                  button: true,
                  child: IconButton(
                    icon: Icon(
                      _isListening ? Icons.mic : Icons.mic_none,
                      color: _isListening ? Colors.red : Colors.amber,
                      semanticLabel: _isListening ? 'Stop listening' : 'Voice search',
                    ),
                    onPressed: _isListening ? _stopListening : _startListening,
                  ),
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
                return Semantics(
                  label: '${building.name}, ${building.entrances.length} entrance${building.entrances.length != 1 ? 's' : ''}. Tap to navigate.',
                  button: true,
                  child: ListTile(
                    leading: const Icon(Icons.location_on, color: Colors.amber, semanticLabel: 'Location'),
                    title: Text(building.name),
                    subtitle: Text(
                      '${building.entrances.length} entrance${building.entrances.length != 1 ? 's' : ''}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () => _onBuildingSelected(building),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

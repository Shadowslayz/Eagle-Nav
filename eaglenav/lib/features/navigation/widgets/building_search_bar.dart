/* A search bar widget for finding and selecting campus buildings.
/
/ Queries [BuildingSearchService] on each keystroke and displays a live
/ dropdown of matching results by building name or ID. Selecting a result
/ fills the search field, dismisses the dropdown, and fires the
/ [onBuildingSelected] callback. Includes voice search support. */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Added for HapticFeedback
import 'package:speech_to_text/speech_to_text.dart' as stt;
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

  // Speech to text variables
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isSpeechEnabled = false;
  bool _isListening = false;

  List<Building> _suggestions = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  void _initSpeech() async {
    _isSpeechEnabled = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          if (mounted) {
            setState(() {
              _isListening = false;
            });
          }
        }
      },
      onError: (errorNotification) {
        if (mounted) {
          setState(() {
            _isListening = false;
          });
        }
      },
    );
    setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _speech.cancel();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    setState(() {
      _isLoading = true;
    });

    try {
      final results = await _searchService.searchBuildings(query);
      results.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );

      if (mounted) {
        setState(() {
          _suggestions = results;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Search error: $e');
      if (mounted) {
        setState(() {
          _suggestions = [];
          _isLoading = false;
        });
      }
    }
  }

  void _onBuildingSelected(Building building) {
    _controller.text = building.name;
    _focusNode.unfocus();

    if (_isListening) {
      _speech.stop();
    }

    setState(() {
      _suggestions = [];
      _isListening = false;
    });

    widget.onBuildingSelected?.call(building);
  }

  // Updated toggle function with delay and haptic feedback
  void _toggleVoiceSearch() async {
    if (_isListening) {
      _speech.stop();
      setState(() {
        _isListening = false;
      });
    } else {
      if (_isSpeechEnabled) {
        setState(() {
          _isListening = true;
          _controller.clear();
        });

        // 1. Wait 1.5 seconds to let the screen reader finish its announcement
        await Future.delayed(const Duration(milliseconds: 1500));

        // Ensure the user didn't cancel during the delay before starting the mic
        if (!mounted || !_isListening) return;

        // 2. Vibrate the phone so the user knows it's time to speak
        HapticFeedback.heavyImpact();

        _speech.listen(
          onResult: (result) {
            setState(() {
              _controller.text = result.recognizedWords;
            });
            _performSearch(result.recognizedWords);
          },
          pauseFor: const Duration(seconds: 8),
          listenFor: const Duration(seconds: 30),
          partialResults: true,
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Microphone permission denied or unavailable."),
          ),
        );
      }
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
                  excludeFromSemantics: true,
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
                  onTap: () {
                    _performSearch(_controller.text);
                  },
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
                Semantics(
                  label: _isListening ? '' : 'Voice search',
                  button: true,
                  excludeSemantics: true,
                  child: IconButton(
                    icon: Icon(
                      _isListening ? Icons.mic : Icons.mic_none,
                      color: Colors.amber,
                    ),
                    onPressed: _toggleVoiceSearch,
                  ),
                ),
            ],
          ),
        ),
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
            constraints: const BoxConstraints(maxHeight: 250),
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

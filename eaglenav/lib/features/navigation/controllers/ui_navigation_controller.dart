import 'package:flutter/material.dart';

enum NavigationUIState { idle, destinationSelected, navigating, arrived }

class UiNavigationController extends ChangeNotifier {
  NavigationUIState _state = NavigationUIState.idle;
  NavigationUIState get state => _state;

  dynamic _selectedDestination;
  dynamic get selectedDestination => _selectedDestination;

  // set the state type based on the navigation state
  void setState(NavigationUIState newState, {dynamic destination}) {
    _state = newState;
    if (destination != null) _selectedDestination = destination;
    notifyListeners();
  }
}

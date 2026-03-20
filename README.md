# Augmented-Reality-Navigation-System-for-CSULA

##  Getting Started

Follow these steps to set up the development environment and run **Eagle-Nav** locally.

### 1. Clone the Repository
Open your terminal and run the following commands to clone the project and enter the directory:
```bash
git clone -b Path-Tracing-MVP https://github.com/Shadowslayz/Eagle-Nav.git
cd Eagle-Nav/eaglenav
```

### 2. Resolve Dependencies
If you see red error lines in your IDE or terminal, it’s usually because the local packages aren't synced. Run this command to install all necessary Flutter and Dart dependencies:
`flutter pub get`

### 3. Setup the Emulator
To see the app in action, you need to launch a mobile device:
1. Open the project in VS Code.

2. Look at the bottom-right corner of the window. Click where it says "Chrome (web-javascript)" or "No Device."

3. A menu will appear at the top. Select an existing Mobile Emulator (Android or iOS).

4. If you don't have one, select "Create Android Emulator" and follow the setup prompts.

### 4. Run the App
Once the emulator is booted up and visible on your screen, execute the run command:
`flutter run`

## Development Shortcuts: The "r" Keys
Flutter provides two ways to update your app instantly without needing to stop and restart the entire build process.

- Hot Reload (Press r in the terminal):

  - What it does: Updates the code and paints the changes to the UI almost instantly.

  - The Benefit: It maintains the "State." For example, if you are logged in and on a specific settings page, hitting r keeps you on that page while showing your new code changes. Use this for UI tweaks and small logic fixes.

- Hot Restart (Press R in the terminal):

  - What it does: Recompiles the app and restarts it from the beginning.

  - The Benefit: Use this when you make major changes to the app's initialization (like main() or initState()). It is faster than a full stop/start, but it wipes the "State". This way the app will return to the loading screen.
 
---
Navigation & Path Injection: 
If you are working on the routing engine, custom paths, or Valhalla integration, please refer to the detailed technical guides here:

- [Navigation Setup Guide](https://github.com/Shadowslayz/Eagle-Nav/blob/Path-Tracing-MVP/eaglenav/Routing_Setup/README.md)
- [Path Injection Setup Guide](https://github.com/Shadowslayz/Eagle-Nav/blob/Path-Tracing-MVP/eaglenav/assets/data/valhalla/path_injection.md)

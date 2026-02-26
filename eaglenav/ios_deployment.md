# Running EagleNav on a Physical iPhone

This guide walks you through running EagleNav on your iPhone from Xcode. You do **not** need a paid Apple Developer account ($99/yr), which is a free Apple ID works fine for local development. The only limitation is that the app will need to be re-signed every 7 days, but this is not a painful process: Xcode re-signs automatically when you hit run.

---

## Prerequisites

- Xcode installed
- iPhone connected via USB
- Flutter installed and `flutter doctor` passing for iOS

Before anything else, install the iOS dependencies. Open a terminal, navigate to the `eaglenav` folder, and run:

```bash
cd ios
pod install
cd ..
```

---

## Step 1: Enable Developer Mode on Your iPhone

> Do this first — without it, Xcode cannot deploy to your device.

On your iPhone go to `Settings > Privacy & Security > Developer Mode` and enable it. Your phone will restart.

---

## Step 2: Connect Your iPhone

1. Plug your iPhone into your Mac via USB.
2. Make sure your iPhone is **unlocked** when plugging in — Xcode cannot communicate with a locked screen.
3. Tap **Trust** on the iPhone when the "Trust This Computer" prompt appears and enter your passcode.
4. If nothing happens after tapping Trust, try unplugging and replugging the USB cable.

> The phone does not need to be signed into the same Apple ID as your Mac.

---

## Step 3: Open the Project in Xcode

From your terminal, navigate to the Flutter project root and run:

```bash
open ios/Runner.xcworkspace
```

> Make sure you open the `.xcworkspace` file, **not** the `.xcodeproj`. Do not open the project by selecting an existing repo from the Xcode start screen, since this will not load the project correctly.

---

## Step 4: Find the Runner Project File

In Xcode, make sure the **Project Navigator** is open (the folder icon, first tab in the left sidebar). At the very top of the file tree, look for a file with a blue icon that resembles the Xcode hammer logo named **Runner**. It sits above all the folders. This is the project file, not the `Runner` folder inside `ios/`.

---

## Step 5: Sign the App

1. Click the blue **Runner** icon at the top of the sidebar.
2. Click the **Signing & Capabilities** tab in the main panel.
3. You will likely see an error about a missing provisioning profile — this is expected until a Team is set.
4. Under **Team**, click the dropdown (it will show "None") and select **Add an Account**.
5. Sign in with your Apple ID. Once added, select your personal team — it will appear as `Your Name (Personal Team)`.
6. Xcode will auto-generate the provisioning profile and the error will clear.

**Also update the Bundle Identifier** — Apple blocks provisioning profiles for IDs starting with `com.example`. Change it to something unique like:
```
com.eaglenav.app
```

---

## Step 6: Monitor Your Device in Devices & Simulators

Open `Window > Devices and Simulators` and keep this window open alongside your work. It shows the pairing status of your iPhone and any errors in real time — it is the best place to catch what is going wrong if something fails.

When you first connect, Xcode will say `Copying shared cache symbols from [your iPhone]` with a progress bar. This is normal and only happens once.

---

## Step 7: Install iOS Device Support if Needed

If Xcode shows an error that your iOS version is not installed, go to:

`Xcode > Settings > Platforms`

Find iOS in the list and download the version that matches your iPhone. Once installed, the error will clear.

---

## Step 8: Update app_config.dart with Your Machine's IP

The app connects to the Valhalla routing server running on your machine via Docker.
On an emulator this works automatically, but a physical iPhone is on your WiFi
network and needs your machine's actual local IP address to reach it.

Open `lib/config/app_config.dart` and update the `_localNetworkIp` field:

```dart
static const String _localNetworkIp = '192.168.x.x'; // ← replace this
```

### Finding your IP

**Mac:**
```bash
ipconfig getifaddr en0
```

**Windows:**
```bash
ipconfig
# look for "IPv4 Address" under your WiFi adapter
```

**Linux:**
```bash
ip route get 1 | awk '{print $7}'
```

The result will look like `192.168.1.42` or `10.0.0.5`. Paste that value into
`_localNetworkIp`. Your iPhone and your machine must be on the **same WiFi network**
for this to work.

> **Heads up:** Your local IP can change if your router reassigns it (e.g. after a
> restart). If routing stops working on the physical device, re-run the command above
> and update the field. To avoid this permanently, set a static IP for your machine
> in your router's DHCP settings.

---

## Step 9: Run the App

Once your device is paired, signing is set up, and the IP is updated, open the
**eaglenav** project in VS Code. Open the integrated terminal (`Terminal > New Terminal`)
and make sure you are inside the `eaglenav` folder, then run with the physical device flag:

### Quick development build
```bash
flutter run --dart-define=PHYSICAL_DEVICE=true
```
Use this during active development. The app compiles faster in debug mode and
supports hot reload (`r` in the terminal to reload, `R` to restart). Performance
will feel slightly slower than the final app — this is normal.

### Standalone release build
```bash
flutter run --release --dart-define=PHYSICAL_DEVICE=true
```
Use this when you want to test the app as it will actually feel for a real user —
full performance, no debug overhead. Takes longer to compile (a few minutes) but
the result runs independently on the phone without needing the Mac connected.
Hot reload is not available in release mode.

> **Rule of thumb:** use `flutter run` while iterating on features, switch to
> `flutter run --release` when testing navigation performance, GPS accuracy,
> or showing the app to someone.

> **Keychain prompt:** The first time you run, macOS will show a system dialog
> saying `codesign wants to access "Apple Development" in your keychain`. Enter
> your **Mac login password** and click **Always Allow** so it doesn't prompt
> on every build.

> **Trust the Developer Certificate on your iPhone:** After the first build, the
> app may be blocked on your device. Go to
> `Settings > General > VPN & Device Management`, select your Developer App
> certificate, and tap **Trust**.

---

## Re-signing After 7 Days

With a free Apple ID, the provisioning profile expires every 7 days. To re-sign,
simply open Xcode and hit the play button — Xcode handles it automatically. It is
not as painful as it sounds.
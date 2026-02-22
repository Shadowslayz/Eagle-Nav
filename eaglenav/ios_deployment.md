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

## Step 8: Run the App

Once your device is paired and signing is set up, open the **eaglenav** project in VS Code. Open the integrated terminal (`Terminal > New Terminal`) and make sure you are inside the `eaglenav` folder — you should see it in the terminal prompt. Then run:

```bash
cd eaglenav
flutter run
```

> Make sure the terminal is opened from within the `eaglenav` folder in VS Code, not a parent directory. Running `flutter run` from the wrong directory is a common reason it fails to find the project.

Flutter will detect your iPhone and deploy the app to it.

> **Keychain prompt:** The first time you run, macOS will show a system dialog saying `codesign wants to access "Apple Development" in your keychain`. Enter your **Mac login password** and click **Always Allow** so it doesn't prompt you on every build.

> **Trust the Developer Certificate on your iPhone:** After the first build, the app may be blocked on your device. Go to `Settings > General > VPN & Device Management`, select your Developer App certificate, and tap **Trust**.

---

## Re-signing After 7 Days

With a free Apple ID, the provisioning profile expires every 7 days. To re-sign, simply open Xcode and hit the play button — Xcode handles it automatically. It is not as painful as it sounds.
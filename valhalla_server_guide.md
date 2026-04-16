# Valhalla Server — Step-by-Step Setup Guide

> This guide walks a new developer through the complete process of getting the Valhalla
> routing server online from scratch — from uploading tiles to a live 24/7 server.
> Read `VALHALLA_INFRASTRUCTURE.md` first if you want to understand *why* things are
> set up this way.

---

## Overview

```
What you will set up:

  Your Machine                Cloudflare R2              Google Cloud VM
  ┌──────────────┐           ┌──────────────┐           ┌──────────────────────┐
  │ Valhalla_    │  upload   │ valhalla-    │  pulls    │ Docker               │
  │ CSULA/       │ ────────▶ │ data bucket  │ ────────▶ │ Valhalla server      │
  │  ├ *.pbf     │  via      │  ├ *.pbf     │  on       │ port 8002            │
  │  └ valhalla_ │  browser  │  └ valhalla_ │  startup  │ runs 24/7            │
  │    tiles/    │           │    tiles/    │           └──────────────────────┘
  └──────────────┘           └──────────────┘
        (local)                  (free)                      (free)
```

**Prerequisites:**
- Docker Desktop installed and working locally
- The `Valhalla_CSULA/` folder with tiles already built
- A Cloudflare account (free)
- A Google Cloud account (free)

---

## Part 1 — Cloudflare R2 Setup (Storage)

### 1.1 Create a Cloudflare Account

1. Go to [cloudflare.com](https://cloudflare.com) → **Sign Up**
2. Use a team or shared email if possible — whoever owns this account owns the storage
3. Verify your email

### 1.2 Create the R2 Bucket

1. In the Cloudflare dashboard, click **R2 Object Storage** in the left sidebar
2. You will be asked to add a credit card — this is required by Cloudflare even for the
   free tier, but **you will not be charged** at this file size (well within the 10 GB free limit)
3. Click **Create bucket**
   - **Name:** `valhalla-data`
   - **Region:** leave as default (automatic)
4. Click **Create bucket**

### 1.3 Enable Public Access

1. Click into the `valhalla-data` bucket
2. Go to the **Settings** tab
3. Scroll to **Public Access**
4. Click **Enable** under **Public Development URL**
5. Copy the URL that appears — it looks like:
   ```
   https://pub-XXXXXXXXXXXXXXXX.r2.dev
   ```
6. **Save this URL** — you will need it in Part 2 and Part 3

> This URL is how the Google Cloud VM will download your tiles and PBF on startup.

### 1.4 Upload the Tiles and PBF

> **Good news:** There are no file size issues with the Cloudflare dashboard.
> Upload everything directly through the browser — no CLI tools needed.

**Check your PBF filename first:**

Open `Valhalla_CSULA/` on your machine and note the exact name of the `.pbf` file.
The file has been renumbered so it may not be literally `osm.pbf` — use whatever
the actual filename is throughout this guide.

**Upload the PBF file:**
1. Inside the `valhalla-data` bucket, click **Upload**
2. Click **Upload Files**
3. Select the `.pbf` file from `Valhalla_CSULA/`
4. Wait for upload to complete

**Upload the tiles folder:**
1. Click **Upload** again
2. Click **Upload Folder**
3. Select the `valhalla_tiles/` folder from inside `Valhalla_CSULA/`
4. Wait for all files to upload (may take a few minutes)

**Verify the bucket looks like this:**
```
valhalla-data/
├── your-region-file.pbf      ← the renamed PBF file
└── valhalla_tiles/
    ├── 0/
    ├── 1/
    ├── 2/
    └── ...
```

### 1.5 Verify Public Access is Working

Paste this into your browser (replace with your actual values):
```
https://pub-XXXXXXXXXXXXXXXX.r2.dev/your-region-file.pbf
```

It should prompt a file download. If it does — **R2 is set up correctly.**

---

## Part 2 — Google Cloud VM Setup (Server)

### 2.1 Create a Google Cloud Account

1. Go to [cloud.google.com](https://cloud.google.com) → **Get started for free**
2. Sign in with a Google account
3. You will need to enter a credit card — Google **will not charge you** as long as you
   stay on free tier resources (the e2-micro VM is always free)
4. Complete account setup

### 2.2 Navigate to Compute Engine

Google Cloud's UI can be overwhelming at first. Here's the most reliable way to get around:

**To find Compute Engine:**
1. Click the **hamburger menu ☰** (three horizontal lines) in the **top left corner**
2. Scroll down and click **Compute Engine**
3. Click **VM Instances** in the left sidebar

**If you ever get lost:**
- Click the **Google Cloud logo** in the very top left → takes you back to the home dashboard
- Use the **search bar at the top** and type `VM Instances` → click the first result

> **Note:** When you first open Compute Engine, it may ask you to **Enable the Compute Engine API** — click Enable and wait about 1 minute before proceeding.

### 2.3 Create the VM

1. From the VM Instances page, click **Create Instance**
2. Fill in these settings:

   | Setting | Value |
   |---|---|
   | **Name** | `valhalla-server` |
   | **Region** | `us-west1 (Oregon)` |
   | **Zone** | `us-west1-b` |
   | **Machine type** | `e2-micro` (under General Purpose → E2) — should say **"Free tier eligible"** |
   | **Boot disk** | Click **Change** → **Ubuntu 22.04 LTS** → **Standard persistent disk** → **30 GB** → **Select** |
   | **Firewall** | Check both **Allow HTTP traffic** and **Allow HTTPS traffic** |

3. Click **Create** at the bottom — VM is ready in ~30 seconds

> **⚠️ The cost estimator will show ~$6.51/month — ignore it.**
> Google Cloud's estimate preview does NOT apply free tier discounts. As long as you have
> `us-west1`, `e2-micro`, and standard persistent disk selected, your actual bill will be
> **$0.00**. The free tier credit is applied automatically when the real invoice is generated.
> To verify after your first month: go to **Billing → Credits** in the Console — you'll see
> the free tier discount offsetting the cost to zero. You can also check your running costs
> anytime at **Billing → Reports** in the left sidebar.

> **Why e2-micro and not e2-medium?**
> e2-medium has 4 GB RAM vs 1 GB, which sounds better — but it costs **~$27/month** and is
> not free tier eligible. Since tiles are pre-built locally and the server only *serves* routes,
> RAM usage stays around 200–400 MB, well within the 1 GB limit. Start free with e2-micro.
> If it ever struggles under real traffic (slow responses, container crashing), that's your
> signal to upgrade — Google Cloud lets you resize a VM in ~2 minutes without losing anything.

> **Why us-west1 (Oregon) and not Los Angeles?**
> Google's always-free e2-micro is only available in 3 regions: `us-west1` (Oregon),
> `us-central1` (Iowa), and `us-east1` (South Carolina). Los Angeles is `us-west2` which
> is **not free** and will incur charges. Oregon is the closest free region to LA.
> The latency difference (~20ms) is completely imperceptible in a routing app.

> **Why not just pick the region automatically?**
> If you let Google choose, it may pick a paid region. Always set it manually to `us-west1`.

### 2.4 Find Your External IP

After the VM is created it will take you to the settings page. Here's how to find the External IP:

1. Click the **hamburger menu ☰** → **Compute Engine** → **VM Instances**
2. You'll see `valhalla-server` in the list with a **green circle** ● on the left
3. The **External IP** is a number like `34.xxx.xxx.xxx` shown in the table
4. **Copy and save this IP** — it's your server's permanent public address

### 2.3 Open Port 8002

By default, Google Cloud blocks all ports except 80 and 443. You need to open port 8002 for Valhalla.

1. In Google Cloud Console, go to **VPC Network** → **Firewall**
2. Click **Create Firewall Rule**
   - **Name:** `allow-valhalla`
   - **Direction:** Ingress
   - **Action:** Allow
   - **Targets:** All instances in the network
   - **Source IP ranges:** `0.0.0.0/0`
   - **Protocols and ports:** TCP → `8002`
3. Click **Create**

### 2.4 SSH Into the VM

From the VM Instances page, click the **SSH** button next to your VM — this opens
a browser-based terminal. No local SSH setup needed.

### 2.5 Install Docker

In the SSH terminal, run these commands one at a time:

```bash
# Update package list
sudo apt-get update

# Install Docker
curl -fsSL https://get.docker.com | sudo sh

# Add your user to the docker group (so you don't need sudo every time)
sudo usermod -aG docker $USER

# Apply group change (or log out and back in)
newgrp docker
```

Verify Docker is working:
```bash
docker --version
```

### 2.6 Create the Valhalla Project Folder

```bash
mkdir ~/valhalla
cd ~/valhalla
nano docker-compose.yml
```

Paste the following — replace the values in `< >` with your actual values:

```yaml
services:
  valhalla:
    image: ghcr.io/nilsnolde/docker-valhalla/valhalla:latest
    ports:
      - "8002:8002"
    volumes:
      - valhalla_tiles:/custom_files
    restart: always
    environment:
      - tile_urls=https://pub-XXXXXXXXXXXXXXXX.r2.dev/your-region-file.pbf
      - serve_tiles=True
      - build_time_filter_ids=False

volumes:
  valhalla_tiles:
```

> - `tile_urls` — replace with your R2 Public Development URL + your actual PBF filename
> - `restart: always` — the container will automatically restart after crashes or reboots

Save the file: `Ctrl+X` → `Y` → `Enter`

### 2.7 Authenticate with GitHub Container Registry

The Valhalla Docker image is hosted on GitHub's registry and requires authentication to pull.
You need a free GitHub Personal Access Token:

**Create the token:**
1. Go to [github.com](https://github.com) → sign in (or create a free account)
2. Click your **profile photo** (top right) → **Settings**
3. Scroll to the bottom of the left sidebar → **Developer settings**
4. Click **Personal access tokens** → **Tokens (classic)**
5. Click **Generate new token** → **Generate new token (classic)**
   - **Note:** `valhalla-docker`
   - **Expiration:** No expiration
   - **Scopes:** check only `read:packages`
6. Click **Generate token**
7. **Copy the token immediately** — it starts with `ghp_...` and you cannot see it again after leaving the page

**Log in from the SSH terminal:**
```bash
docker login ghcr.io -u YOUR_GITHUB_USERNAME
```

When it asks for a **Password**, paste your `ghp_...` token and press Enter.

> **The password will not be visible as you type or paste — this is normal terminal security behavior. Just paste the token and press Enter even though nothing appears on screen.**

### 2.8 Launch Valhalla

### 2.8 Launch Valhalla

```bash
docker compose up -d
```

Watch the startup logs:
```bash
docker compose logs -f
```

The first run will:
1. Pull the Docker image (~1-2 min)
2. Download the PBF from R2
3. Load the pre-built tiles
4. Start serving

When you see output containing `Valhalla running`, the server is live.

Press `Ctrl+C` to stop watching logs (the server keeps running in the background).

### 2.9 Verify the Server is Working

From your local machine, open a browser or run:
```bash
curl http://YOUR_VM_EXTERNAL_IP:8002/status
```

You should get a JSON response like:
```json
{
  "version": "3.5.x",
  "tileset_last_modified": 1234567890,
  "available_actions": ["status","route","isochrone","sources_to_targets",...]
}
```

**A response with `available_actions` and a `tileset_last_modified` timestamp means everything is working correctly.**

> **Note:** The `traffic.tar` warnings in the logs are completely normal — that's real-time
> traffic data which is not part of this setup. Ignore them.

---

## Part 3 — Updating the Map Data in the Future

When the PBF changes (new map data, different coverage area), follow these steps:

```
Step 1              Step 2                Step 3              Step 4
───────────         ──────────────        ────────────────    ──────────────
Get new .pbf        Build tiles           Upload to R2        Restart VM
file into     ────▶ locally with    ────▶ dashboard      ────▶ container
Valhalla_CSULA      Docker                (overwrite old)
```

### Step 1 — Replace the PBF

Put the new `.pbf` file into `Valhalla_CSULA/` on your local machine.

### Step 2 — Build Tiles Locally

```bash
# Navigate to the Valhalla_CSULA folder
cd /path/to/Valhalla_CSULA

# Run the tile builder (this will take a few minutes)
docker run -it --rm \
  -v $(pwd):/custom_files \
  ghcr.io/nilsnolde/docker-valhalla/valhalla:latest \
  build_tiles
```

The `valhalla_tiles/` folder will be updated when complete.

### Step 3 — Upload to R2

1. Go to Cloudflare R2 dashboard → `valhalla-data` bucket
2. Delete the old `valhalla_tiles/` folder
3. Click **Upload** → **Upload Folder** → select the new `valhalla_tiles/`
4. Also replace the `.pbf` file if the filename changed

### Step 4 — Restart the Server

Click the **SSH** button on your Google Cloud VM and run:
```bash
# 1. Navigate to your Valhalla folder
cd ~/valhalla

# 2. Shut down the server AND delete the old cached map volume (very important)
docker compose down -v

# 3. Start the server back up (it will now download the new map from Cloudflare)
docker compose up -d
```

The container will re-download tiles from R2 and be back online within ~1 minute.

---

## Troubleshooting

**Server returns `"has_tiles": false`**
→ Tiles did not load correctly. Check `docker compose logs` for errors.
→ Verify the R2 public URL is accessible from your browser.

**Container keeps restarting**
→ Likely out of memory. Run `docker compose logs` to confirm OOM errors.
→ The tile folder may have grown too large for the e2-micro. See upgrade path in `VALHALLA_INFRASTRUCTURE.md`.

**Can't reach port 8002**
→ Double-check the firewall rule was created correctly in Google Cloud VPC Network.
→ Make sure you are using the **External IP**, not the Internal IP.

**Upload to R2 stalls or fails**
→ Try a different browser or split the upload into smaller batches of subfolders.
→ This has not been an issue in practice — the dashboard handles the full tile folder fine.

**`tile_urls` PBF filename mismatch**
→ The PBF in R2 and the filename in `docker-compose.yml` must match exactly.
→ Check both and correct the `tile_urls` value, then `docker compose up -d` again.

---

## Part 4 — Flutter App Configuration

### 4.1 Point the App at the Cloud Server

Update `lib/app_config.dart` (or wherever `AppConfig` lives) to use the cloud server.
Since the server is now live and reachable from anywhere, all devices use the same URL:

```dart
import 'dart:io';

class AppConfig {
  // Cloud server - runs 24/7, reachable from any device including physical iPhones
  static const String _cloudServerIp = '136.117.68.104';

  static String get valhallaBaseUrl {
    return 'http://$_cloudServerIp:8002';
  }
}
```

> If the server IP ever changes (e.g. after a VM rebuild), update `_cloudServerIp` here
> and rebuild the app.

### 4.2 Allow HTTP on iOS (Required)

Apple blocks plain `http://` requests by default on iOS. Since the server uses HTTP (not HTTPS),
you need to add a security exception in `ios/Runner/Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSExceptionDomains</key>
    <dict>
        <key>136.117.68.104</key>
        <dict>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <true/>
        </dict>
    </dict>
</dict>
```

> **Where to add it:** Open `ios/Runner/Info.plist` and paste this block inside the root
> `<dict>` tag, alongside the other existing keys.

> **Future improvement:** If you add a domain name + HTTPS to the server (via Caddy —
> see `VALHALLA_INFRASTRUCTURE.md`), you can remove this exception entirely and iOS
> will work without any special config.

### 4.3 Android

No extra configuration needed — Android allows HTTP traffic to IP addresses by default
in debug and release builds.

---



| Task | Where / How |
|---|---|
| PBF location | `Valhalla_CSULA/` — check actual filename |
| Tile location | `Valhalla_CSULA/valhalla_tiles/` |
| R2 bucket | `valhalla-data` on Cloudflare R2 |
| R2 public URL | R2 → bucket → Settings → Public Development URL |
| VM SSH access | Google Cloud Console → VM Instances → SSH button |
| Valhalla port | `8002` |
| Start server | `docker compose up -d` |
| Restart server | `docker compose restart` |
| View logs | `docker compose logs -f` |
| Check status | `curl http://YOUR_VM_IP:8002/status` |
| Build tiles locally | `docker run ... build_tiles` (see Step 2 above) |

---

## Accounts and Access

> **Important:** Make sure the team has access to both of these accounts.
> If the person who set them up leaves, recovery becomes difficult.

| Service | URL | What it controls |
|---|---|---|
| Cloudflare | [dash.cloudflare.com](https://dash.cloudflare.com) | R2 storage, tile files, PBF file |
| Google Cloud | [console.cloud.google.com](https://console.cloud.google.com) | VM server, firewall, uptime |

---

*Last updated: March 2026*
*See `VALHALLA_INFRASTRUCTURE.md` for architecture decisions and upgrade path.*
# EagleNav: Injecting Custom Paths into OSM Data

EagleNav uses Valhalla as its routing engine, which builds its routing graph from a local PBF file of the CSULA campus. Because the global OSM database is missing many of the campus's walking paths and accessible ramps, we manually inject custom paths directly into our local PBF using JOSM before feeding it to Valhalla.

---

## Path Injection with JOSM

### 1. Initial Setup

1. [Download JOSM](https://josm.openstreetmap.de/wiki/Download) and install the version for your OS.
2. Open the campus PBF file: go to `File > Open` and select your `.osm.pbf` file.
3. Once loaded, you'll see the existing map data rendered as a wireframe — lines and nodes representing the roads and paths OSM already knows about. Anything missing here is a path Valhalla can't route through.

---

### 2. Enable Satellite Imagery

To draw accurate paths, you need a visual reference.

1. Go to the `Imagery` tab in the top menu.
2. Select `Bing Aerial Imagery`.

> **Why Bing?** It typically offers the highest resolution for campus environments, making it easier to see sidewalks and ramps that aren't on the base map.

---

### 3. Install the PBF Plugin

By default, JOSM saves files in XML format. Since Valhalla requires PBF, we need to install a plugin.

Open Preferences:
- **Windows/Linux:** `Edit > Preferences` (or press `F12`)
- **macOS:** `JOSM > Preferences` (or press `Cmd + ,`)

Then:

1. Click the **Plugins** icon (blue puzzle piece).
2. Click **Download List** to refresh available plugins.
3. Search for `pbf`.
4. Check the box for the pbf plugin and click **OK**.

> JOSM may require a restart to finalize the installation.

---

### 4. Navigating & Drawing Paths

**Navigation controls:**
- **Zoom:** Mouse wheel or `+` / `-` keys
- **Pan:** Right-click and drag

**Drawing the path:**

1. Zoom in until you can see the yellow square nodes on existing paths.
2. Press `A` to enter Add Mode — your cursor will become a crosshair.
3. Click an existing node to snap your new path to the network.
4. Click to place new points along your path, and double-click to finish the line.

---

### 5. Adding Tags (Crucial for Valhalla)

A line in JOSM is just a "way", so it has no purpose until you tag it. Without the correct tags, Valhalla won't know if this is a road, a sidewalk, or a fence, and the Docker build will fail.

1. Press `S` to enter Select mode, then click your new path.
2. In the **Tags/Memberships** panel on the right, click **Add**.
3. Enter the following:
   - **Key:** `highway`
   - **Value:** `footway`
4. Click **OK**. This tells Valhalla the path is routable for pedestrians.

---

### 6. Validation and Saving

Before saving, check that your new path has no errors.

1. Press `Shift + V` to run validation.
2. Check the **Validation Results** window. Ignore warnings, but fix any **Errors** such as disconnected paths (these will cause the Docker image build to fail.)
3. Go to `File > Save` to save the file.

---

## Preparing the PBF for Valhalla

After saving from JOSM, the file must be sorted and renumbered before Valhalla can consume it. Skipping this step will cause the Docker build to fail with a `Detected unsorted input data` error.

In your terminal, navigate to the directory containing the PBF file and run:

```bash
# 1. Sort the data
osmium sort CSULA.osm.pbf -o sorted_file.osm.pbf

# 2. Renumber the IDs
osmium renumber sorted_file.osm.pbf -o final_file.osm.pbf
```

---

## Running Valhalla on Docker

We use `./start_valhalla.sh` to build and deploy the Valhalla routing engine in a Docker container.

> ⚠️ **Important:** The `start_valhalla.sh` script is greedy, so it will attempt to build a routing graph from **every** `.pbf` file it finds in the `Valhalla_CSULA` folder. If more than one PBF file is present, Valhalla will try to merge them, which will cause an unsorted data crash or a corrupted routing graph.

**Before running the script, ensure the `Valhalla_CSULA` folder contains only the single PBF file you intend to use.**

Navigate to the Valhalla_CSULA and run the server with the updated PBF:
```bash
./start_valhalla.sh
```
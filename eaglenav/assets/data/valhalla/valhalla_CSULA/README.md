# Valhalla Server for CSULA Campus

This directory contains the OpenStreetMap data and scripts to run a local Valhalla routing server for Cal State LA campus navigation.

## Prerequisites
- Docker installed and running
- 2-4GB free disk space (for tiles generation)

## Quick Start

1. **Navigate to this directory:**
```bash
   cd assets/data/valhalla/valhalla_CSULA
```

2. **Start Valhalla server:**
```bash
   ./start_valhalla.sh
```
   
   Or manually:
```bash
   docker run -dt \
     --name valhalla_csula \
     -p 8002:8002 \
     -v "$(pwd)":/custom_files \
     -e force_rebuild=True \
     ghcr.io/gis-ops/docker-valhalla/valhalla:latest
```

3. **Wait for build to complete** (first run only, ~2-5 minutes):
```bash
   docker logs -f valhalla_csula
```
   
   Look for: `"Valhalla is ready!"` or similar message

4. **Test the server:**
```bash
   curl http://localhost:8002/status
```
   
   Should return: `{"available":true}`

## Files Generated

The Docker container will automatically generate these files (already in `.gitignore`):
- `valhalla_tiles/` - Routing graph tiles
- `valhalla_tiles.tar` - Compressed tiles
- `valhalla.json` - Server configuration
- Build logs and temp files

**Don't commit these** They're large (~500MB+) and generated from `CSULA.osm.pbf`

## Stopping the Server
```bash
docker stop valhalla_csula
docker rm valhalla_csula
```

```

```

**Can't access from Android emulator:**
- Emulator users: Use `http://10.0.2.2:8002` (already configured in `app_config.dart`)

## What's in this directory

- `CSULA.osm.pbf` - OpenStreetMap data (source)
- `start_valhalla.sh` - Startup script
- `README.md` - This file
- `valhalla_tiles/` - Generated tiles (ignored)
- `valhalla.json` - Generated config (ignored)
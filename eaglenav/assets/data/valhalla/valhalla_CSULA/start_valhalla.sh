#!/bin/bash
docker run -dt \
  --name valhalla_csula \
  -p 8002:8002 \
  -v "$(pwd)":/custom_files \
  -e force_rebuild=True \
  ghcr.io/gis-ops/docker-valhalla/valhalla:latest

echo "🚀 Valhalla server starting..."
docker logs -f valhalla_csula

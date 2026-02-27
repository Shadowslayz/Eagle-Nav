@echo off
setlocal enabledelayedexpansion

echo.
echo [94m🔍 Checking prerequisites...[0m
echo.

REM Check if Docker is installed
where docker >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo [91m❌ Error: Docker is not installed or not in PATH[0m
    echo.
    echo [93mPlease install Docker Desktop:[0m
    echo   Download from: https://www.docker.com/products/docker-desktop
    echo.
    echo [93mAfter installation:[0m
    echo   1. Start Docker Desktop
    echo   2. Wait for it to fully start ^(check system tray^)
    echo   3. Run this script again
    echo.
    pause
    exit /b 1
)

REM Check if Docker daemon is running
docker info >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo [91m❌ Error: Docker is installed but not running[0m
    echo.
    echo [93mPlease start Docker Desktop:[0m
    echo   1. Open Docker Desktop from Start Menu
    echo   2. Wait for "Docker Desktop is running" message
    echo   3. Run this script again
    echo.
    pause
    exit /b 1
)

echo [92m✅ Docker is installed and running[0m

REM Check if CSULA.osm.pbf exists
if not exist "CSULA.osm.pbf" (
    echo [91m❌ Error: CSULA.osm.pbf not found in current directory[0m
    echo.
    echo [93mMake sure you're in the correct directory:[0m
    echo   cd assets\data\valhalla\valhalla_CSULA
    echo.
    echo Current directory: %CD%
    echo.
    pause
    exit /b 1
)

echo [92m✅ CSULA.osm.pbf found[0m

REM Check if container already exists
docker ps -a --format "{{.Names}}" | findstr /x "valhalla_csula" >nul 2>nul
if %ERRORLEVEL% equ 0 (
    echo [93m⚠️  Container 'valhalla_csula' already exists[0m
    echo [94mRemoving old container...[0m
    docker rm -f valhalla_csula >nul 2>nul
    echo [92m✅ Old container removed[0m
)

REM Check if port 8002 is in use
netstat -an | findstr ":8002.*LISTENING" >nul 2>nul
if %ERRORLEVEL% equ 0 (
    echo [93m⚠️  Port 8002 is already in use[0m
    echo [93mAttempting to free port...[0m
    for /f "tokens=*" %%i in ('docker ps --filter "publish=8002" --format "{{.Names}}"') do (
        docker stop %%i >nul 2>nul
    )
    timeout /t 2 /nobreak >nul
)

echo.
echo [94m🚀 Starting Valhalla server...[0m
echo.

REM Start the container
docker run -dt --name valhalla_csula -p 8002:8002 -v "%CD%:/custom_files" -e force_rebuild=True ghcr.io/gis-ops/docker-valhalla/valhalla:latest

if %ERRORLEVEL% neq 0 (
    echo [91m❌ Failed to start container[0m
    echo [93mCheck the error message above for details[0m
    echo.
    pause
    exit /b 1
)

echo [92m✅ Container started successfully[0m
echo.
echo [94m📋 Watching build progress...[0m
echo [93m^(This will take 2-5 minutes on first run^)[0m
echo [93mPress Ctrl+C to stop watching ^(server will keep running^)[0m
echo.

REM Follow logs
docker logs -f valhalla_csula
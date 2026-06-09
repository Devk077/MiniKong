# docker-start.ps1
# Builds the Docker image and starts the full stack via Docker Compose.
#
# BEFORE running this:
#   - Close the three windows opened by start-all.ps1 (frees ports 8080, 9090, 2112, 5000, 6000)
#   - Confirm Docker Desktop is running: docker info
#
# Press Ctrl+C to stop all containers, then run: docker-compose down

Write-Host ""
Write-Host "Checking Docker is running ..." -ForegroundColor Yellow
try {
    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw }
    Write-Host "Docker is running." -ForegroundColor Green
} catch {
    Write-Host "ERROR: Docker is not running. Start Docker Desktop and try again." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Starting MiniGateway stack (docker-compose up --build) ..." -ForegroundColor Cyan
Write-Host "Wait for all three 'listening on' lines before running test-phase6.ps1" -ForegroundColor Yellow
Write-Host ""

docker-compose up --build

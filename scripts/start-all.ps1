# start-all.ps1
# Opens three separate PowerShell windows: upstream-a, upstream-b, and the gateway.
# Run this first, wait ~8 seconds for `go run` to compile, then run test-phase2.ps1.

$root = "X:\projects\Go\minigateway"

Write-Host ""
Write-Host "Starting upstream-a on :5000 ..." -ForegroundColor Cyan
Start-Process powershell -WorkingDirectory $root -ArgumentList @(
    "-NoExit", "-Command",
    "`$env:SERVER_NAME='upstream-a'; `$env:PORT='5000'; go run ./cmd/mockserver"
)

Write-Host "Starting upstream-b on :6000 ..." -ForegroundColor Cyan
Start-Process powershell -WorkingDirectory $root -ArgumentList @(
    "-NoExit", "-Command",
    "`$env:SERVER_NAME='upstream-b'; `$env:PORT='6000'; go run ./cmd/mockserver"
)

Write-Host "Starting gateway    on :8080 ..." -ForegroundColor Cyan
Start-Process powershell -WorkingDirectory $root -ArgumentList @(
    "-NoExit", "-Command",
    "go run ./cmd/gateway config/gateway.yaml"
)

Write-Host ""
Write-Host "Three windows are opening. Wait about 8 seconds for 'go run' to compile." -ForegroundColor Yellow
Write-Host "Then run:  .\scripts\test-phase2.ps1" -ForegroundColor Yellow
Write-Host ""
Write-Host "To stop everything: close the three windows that just opened." -ForegroundColor DarkGray

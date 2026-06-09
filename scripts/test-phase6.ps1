# test-phase6.ps1
# Verifies the full stack running inside Docker Compose.
# Requires docker-start.ps1 to be running in another terminal first.

$passed = 0
$failed = 0

function Check {
    param([string]$Label, [scriptblock]$Test)
    try {
        $ok = & $Test
        if ($ok) {
            Write-Host "  PASS  $Label" -ForegroundColor Green
            $script:passed++
        } else {
            Write-Host "  FAIL  $Label" -ForegroundColor Red
            $script:failed++
        }
    } catch {
        Write-Host "  FAIL  $Label" -ForegroundColor Red
        Write-Host "        $_" -ForegroundColor DarkRed
        $script:failed++
    }
}

function Get-StatusCode {
    param([string]$Uri, [hashtable]$Headers = @{})
    try {
        $r = Invoke-WebRequest -Uri $Uri -Headers $Headers -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return [int]$r.StatusCode
    } catch {
        try { return [int]$_.Exception.Response.StatusCode.value__ } catch { return 0 }
    }
}

# ---------- wait for gateway ----------
Write-Host ""
Write-Host "Waiting for gateway on :8080 ..." -ForegroundColor Yellow
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    $sc = Get-StatusCode "http://localhost:8080/api/v1/ping"
    if ($sc -in @(200, 401, 429)) { $ready = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $ready) {
    Write-Host "ERROR: Gateway not responding on :8080." -ForegroundColor Red
    Write-Host "       Run .\scripts\docker-start.ps1 in another terminal first." -ForegroundColor Red
    exit 1
}
Write-Host "Gateway is up." -ForegroundColor Green

Write-Host ""
Write-Host "=== Phase 6 Checks (Docker) ===" -ForegroundColor Cyan
Write-Host ""

# ---- routing ----
Write-Host "  -- Routing --" -ForegroundColor DarkCyan

Check "/api/v1/ -> upstream-a (via Docker DNS)" {
    $r = Invoke-WebRequest -Uri "http://localhost:8080/api/v1/ping" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    ($r.Content | ConvertFrom-Json).server -eq "upstream-a"
}

Check "/api/v2/ no credentials -> 401" {
    (Get-StatusCode "http://localhost:8080/api/v2/ping") -eq 401
}

Check "/api/v2/ with credentials -> upstream-b (via Docker DNS)" {
    $h = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:secret")) }
    $r = Invoke-WebRequest -Uri "http://localhost:8080/api/v2/ping" -Headers $h -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    ($r.Content | ConvertFrom-Json).server -eq "upstream-b"
}

# ---- admin api ----
Write-Host ""
Write-Host "  -- Admin API --" -ForegroundColor DarkCyan

Check "GET /admin/routes -> 2 routes" {
    $r = Invoke-WebRequest -Uri "http://localhost:9090/admin/routes" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    ($r.Content | ConvertFrom-Json).Count -eq 2
}

# ---- metrics ----
Write-Host ""
Write-Host "  -- Metrics --" -ForegroundColor DarkCyan

Check "GET :2112/metrics -> Prometheus format" {
    $r = Invoke-WebRequest -Uri "http://localhost:2112/metrics" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $r.Content -match "go_goroutines"
}

Check "minigateway_* metrics present in /metrics" {
    $r = Invoke-WebRequest -Uri "http://localhost:2112/metrics" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $r.Content -match "minigateway_request_duration_seconds"
}

# ---- cache works inside Docker ----
Write-Host ""
Write-Host "  -- Cache inside Docker --" -ForegroundColor DarkCyan

# Send 20 requests to the same URL so cache warms up
$warmUrl = "http://localhost:8080/api/v1/docker-cache-test"
for ($i = 0; $i -lt 20; $i++) {
    Invoke-WebRequest -Uri $warmUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
}

Check "cache_hits_total > 0 after repeated requests" {
    $raw   = (Invoke-WebRequest -Uri "http://localhost:2112/metrics" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop).Content
    $lines = $raw -split "`n"
    $line  = $lines | Where-Object { $_ -match 'minigateway_cache_hits_total\{route="/api/v1/"\}' } | Select-Object -Last 1
    if (-not $line) { return $false }
    if ($line -match '\}\s+([\d.]+)') { return [double]$Matches[1] -gt 0 }
    return $false
}

# ---- summary ----
Write-Host ""
$color = if ($failed -eq 0) { "Green" } else { "Red" }
Write-Host "=== $passed passed, $failed failed ===" -ForegroundColor $color
Write-Host ""
if ($failed -eq 0) {
    Write-Host "Phase 6 complete." -ForegroundColor Green
    Write-Host "Stop the stack with: docker-compose down" -ForegroundColor DarkGray
} else {
    Write-Host "Some checks failed. Share the output above with Claude." -ForegroundColor Red
}
Write-Host ""

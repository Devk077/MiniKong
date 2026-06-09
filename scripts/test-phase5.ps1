# test-phase5.ps1
# Verifies all 5 Prometheus metrics populate with correct labels after real traffic.
# Requires start-all.ps1 to have been run first.
#
# NOTE: Phase 4 tests modified /api/v1/ (disabled cache + ratelimit).
# This script restores the original config automatically via the Admin API
# before generating traffic, so no restart is needed.

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

# Extract the numeric value from a Prometheus text-format line.
# Line format: metric_name{labels} VALUE [timestamp]
function Get-MetricValue {
    param([string[]]$Lines, [string]$Pattern)
    $line = $Lines | Where-Object { $_ -match $Pattern } | Select-Object -Last 1
    if (-not $line) { return 0.0 }
    if ($line -match '\}\s+([\d.]+(?:e[+\-]?\d+)?)') { return [double]$Matches[1] }
    return 0.0
}

# ---------- wait for gateway ----------
Write-Host ""
Write-Host "Waiting for gateway on :8080 ..." -ForegroundColor Yellow
$ready = $false
for ($i = 0; $i -lt 15; $i++) {
    try {
        Invoke-WebRequest -Uri "http://localhost:8080/api/v1/ping" `
            -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop | Out-Null
        $ready = $true; break
    } catch { Start-Sleep -Seconds 1 }
}
if (-not $ready) {
    Write-Host "ERROR: Gateway not responding. Run .\scripts\start-all.ps1 first." -ForegroundColor Red
    exit 1
}
Write-Host "Gateway is up." -ForegroundColor Green

# ---------- restore /api/v1/ to original config ----------
# Phase 4 tests may have disabled cache and rate limiting. Restore here.
Write-Host ""
Write-Host "Restoring /api/v1/ to original config (cache + rate limit enabled) ..." -ForegroundColor Yellow
$originalRoute = '{"path":"/api/v1/","upstream":"service-a","plugins":{"rate_limit":{"enabled":true,"requests_per_second":100.0,"burst":20},"cache":{"enabled":true,"ttl_seconds":30,"max_entries":1000},"auth":{"enabled":false}}}'
try {
    Invoke-WebRequest -Uri "http://localhost:9090/admin/routes" -Method POST `
        -Body $originalRoute -ContentType "application/json" `
        -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
    Write-Host "Config restored." -ForegroundColor Green
} catch {
    Write-Host "WARNING: Could not restore config via Admin API ($_)." -ForegroundColor Yellow
    Write-Host "         If Phase 4 tests ran, restart servers with .\scripts\start-all.ps1" -ForegroundColor Yellow
}

# ---------- generate cache metrics ----------
Write-Host ""
Write-Host "Generating traffic ..." -ForegroundColor Yellow

# Unique URL -> guaranteed MISS on first hit, HIT on second.
$cacheUrl = "http://localhost:8080/api/v1/metrics-verify-phase5"
Invoke-WebRequest -Uri $cacheUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
Invoke-WebRequest -Uri $cacheUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
Write-Host "  Cache traffic sent (1 MISS + 1 HIT)." -ForegroundColor DarkGray

# ---------- generate rate-limit rejections ----------
$rlUri = "http://localhost:8080/api/v1/rl-metrics-test"
$rlScript = {
    param($u)
    try {
        Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 5 | Out-Null
    } catch {}
}

$pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 60)
$pool.Open()
$runspaces = @()
for ($i = 0; $i -lt 60; $i++) {
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($rlScript).AddArgument($rlUri)
    $runspaces += [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
}
$runspaces | ForEach-Object { $_.PS.EndInvoke($_.Handle) | Out-Null; $_.PS.Dispose() }
$pool.Close()
Write-Host "  Rate-limit traffic sent (60 parallel requests)." -ForegroundColor DarkGray

# ---------- scrape /metrics once ----------
Start-Sleep -Milliseconds 200   # brief pause so all counters flush
$raw = (Invoke-WebRequest -Uri "http://localhost:2112/metrics" -UseBasicParsing -TimeoutSec 5).Content
$lines = $raw -split "`n"

# ---------- run checks ----------
Write-Host ""
Write-Host "=== Phase 5 Checks ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  -- All 5 metric families present --" -ForegroundColor DarkCyan

Check "minigateway_request_duration_seconds present" {
    $lines | Where-Object { $_ -match "^minigateway_request_duration_seconds_bucket" } | Select-Object -First 1
}

Check "minigateway_cache_hits_total present" {
    $lines | Where-Object { $_ -match "^minigateway_cache_hits_total" } | Select-Object -First 1
}

Check "minigateway_cache_misses_total present" {
    $lines | Where-Object { $_ -match "^minigateway_cache_misses_total" } | Select-Object -First 1
}

Check "minigateway_ratelimit_rejections_total present" {
    $lines | Where-Object { $_ -match "^minigateway_ratelimit_rejections_total" } | Select-Object -First 1
}

Check "minigateway_upstream_requests_total present" {
    $lines | Where-Object { $_ -match "^minigateway_upstream_requests_total" } | Select-Object -First 1
}

Write-Host ""
Write-Host "  -- Correct label values after traffic --" -ForegroundColor DarkCyan

Check 'cache_hits_total{route="/api/v1/"} > 0' {
    (Get-MetricValue $lines 'minigateway_cache_hits_total\{route="/api/v1/"\}') -gt 0
}

Check 'cache_misses_total{route="/api/v1/"} > 0' {
    (Get-MetricValue $lines 'minigateway_cache_misses_total\{route="/api/v1/"\}') -gt 0
}

Check 'ratelimit_rejections_total{route="/api/v1/"} > 0' {
    (Get-MetricValue $lines 'minigateway_ratelimit_rejections_total\{route="/api/v1/"\}') -gt 0
}

Check 'upstream_requests_total{route="/api/v1/",upstream="service-a"} > 0' {
    (Get-MetricValue $lines 'minigateway_upstream_requests_total\{route="/api/v1/",upstream="service-a"\}') -gt 0
}

Check "upstream_requests_total < total_requests_count (cache is reducing upstream load)" {
    $upstream = Get-MetricValue $lines 'minigateway_upstream_requests_total\{route="/api/v1/"'
    $total    = Get-MetricValue $lines 'minigateway_request_duration_seconds_count\{route="/api/v1/"'
    Write-Host "        upstream=$upstream  total=$total" -ForegroundColor DarkGray
    ($total -gt 0) -and ($upstream -lt $total)
}

Check "request_duration_seconds_bucket has route + upstream + status_code labels" {
    $lines | Where-Object {
        $_ -match 'minigateway_request_duration_seconds_bucket\{' -and
        $_ -match 'route='  -and
        $_ -match 'upstream=' -and
        $_ -match 'status_code='
    } | Select-Object -First 1
}

# ---------- summary ----------
Write-Host ""
$color = if ($failed -eq 0) { "Green" } else { "Red" }
Write-Host "=== $passed passed, $failed failed ===" -ForegroundColor $color
Write-Host ""
if ($failed -eq 0) {
    Write-Host "Phase 5 complete. Tell Claude to start Phase 6 (Docker)." -ForegroundColor Green
} else {
    Write-Host "Some checks failed. Share the output above with Claude." -ForegroundColor Red
}
Write-Host ""

# test-phase2.ps1
# Runs all Phase 2 verification checks against the running gateway.
# Requires start-all.ps1 to have been run first.

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

# ---------- wait for gateway ----------
Write-Host ""
Write-Host "Waiting for gateway to be ready on :8080 ..." -ForegroundColor Yellow
$ready = $false
for ($i = 0; $i -lt 15; $i++) {
    try {
        Invoke-WebRequest -Uri "http://localhost:8080/api/v1/ping" `
            -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop | Out-Null
        $ready = $true; break
    } catch { Start-Sleep -Seconds 1 }
}
if (-not $ready) {
    Write-Host ""
    Write-Host "ERROR: Gateway is not responding on :8080." -ForegroundColor Red
    Write-Host "       Make sure you ran .\scripts\start-all.ps1 and waited ~8 seconds." -ForegroundColor Red
    Write-Host ""
    exit 1
}
Write-Host "Gateway is up." -ForegroundColor Green
Write-Host ""
Write-Host "=== Phase 2 Checks ===" -ForegroundColor Cyan
Write-Host ""

# ---------- check 1 ----------
Check "/api/v1/* routes to upstream-a" {
    $r = Invoke-WebRequest -Uri "http://localhost:8080/api/v1/hello" `
        -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    ($r.Content | ConvertFrom-Json).server -eq "upstream-a"
}

# ---------- check 2 ----------
Check "/api/v2/* routes to upstream-b" {
    $r = Invoke-WebRequest -Uri "http://localhost:8080/api/v2/hello" `
        -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    ($r.Content | ConvertFrom-Json).server -eq "upstream-b"
}

# ---------- check 3 ----------
Check "/unknown/path returns 404" {
    try {
        Invoke-WebRequest -Uri "http://localhost:8080/unknown/path" `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
        $false   # got 2xx — that is wrong
    } catch {
        $_.Exception.Response.StatusCode.value__ -eq 404
    }
}

# ---------- check 4 ----------
Check ":2112/metrics responds with Prometheus format" {
    $r = Invoke-WebRequest -Uri "http://localhost:2112/metrics" `
        -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $r.Content -match "go_goroutines"
}

# ---------- check 5 ----------
Check "minigateway_upstream_requests_total present in /metrics" {
    $r = Invoke-WebRequest -Uri "http://localhost:2112/metrics" `
        -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $r.Content -match "minigateway_upstream_requests_total"
}

# ---------- check 6 ----------
Check "minigateway_request_duration_seconds present in /metrics" {
    $r = Invoke-WebRequest -Uri "http://localhost:2112/metrics" `
        -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $r.Content -match "minigateway_request_duration_seconds"
}

# ---------- check 7 ----------
Check "Consistent hash: 10 requests from same IP always hit same upstream" {
    $servers = @()
    for ($i = 1; $i -le 10; $i++) {
        $r = Invoke-WebRequest -Uri "http://localhost:8080/api/v1/hash-test" `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        $servers += ($r.Content | ConvertFrom-Json).server
    }
    # All 10 responses must come from the same server instance
    ($servers | Select-Object -Unique).Count -eq 1
}

# ---------- summary ----------
Write-Host ""
$color = if ($failed -eq 0) { "Green" } else { "Red" }
Write-Host "=== $passed passed, $failed failed ===" -ForegroundColor $color
Write-Host ""
if ($failed -eq 0) {
    Write-Host "Phase 2 complete. Tell Claude to start Phase 3." -ForegroundColor Green
} else {
    Write-Host "Some checks failed. Review the output above and share it with Claude." -ForegroundColor Red
}
Write-Host ""

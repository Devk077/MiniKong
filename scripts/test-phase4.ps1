# test-phase4.ps1
# Runs all Phase 4 verification checks (Admin API / live route management).
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

function Get-StatusCode {
    param([string]$Uri, [string]$Method = "GET", [string]$Body = "", [hashtable]$Headers = @{})
    try {
        $params = @{
            Uri            = $Uri
            Method         = $Method
            UseBasicParsing = $true
            TimeoutSec     = 5
            ErrorAction    = "Stop"
        }
        if ($Body)    { $params.Body        = $Body }
        if ($Headers.Count -gt 0) { $params.Headers = $Headers }
        $r = Invoke-WebRequest @params
        return [int]$r.StatusCode
    } catch {
        try { return [int]$_.Exception.Response.StatusCode.value__ } catch { return 0 }
    }
}

# ---------- wait for gateway ----------
Write-Host ""
Write-Host "Waiting for gateway on :8080 ..." -ForegroundColor Yellow
$ready = $false
for ($i = 0; $i -lt 15; $i++) {
    $sc = Get-StatusCode "http://localhost:8080/api/v1/ping"
    if ($sc -in @(200, 401, 429)) { $ready = $true; break }
    Start-Sleep -Seconds 1
}
if (-not $ready) {
    Write-Host "ERROR: Gateway not responding. Run .\scripts\start-all.ps1 first." -ForegroundColor Red
    exit 1
}
Write-Host "Gateway is up." -ForegroundColor Green

# ============================================================
Write-Host ""
Write-Host "=== Phase 4 Checks ===" -ForegroundColor Cyan
Write-Host ""

$adminBase   = "http://localhost:9090"
$gatewayBase = "http://localhost:8080"
$jsonHeaders = @{ "Content-Type" = "application/json" }

# ---- CHECK 1: list shows exactly 2 routes ----
Check "GET /admin/routes returns 2 routes on startup" {
    $r = Invoke-WebRequest -Uri "$adminBase/admin/routes" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $routes = $r.Content | ConvertFrom-Json
    $routes.Count -eq 2
}

# ---- CHECK 2: add a new route -> 201 ----
$newRoute = '{"path":"/api/v3/","upstream":"service-a","plugins":{"rate_limit":{"enabled":false,"requests_per_second":0,"burst":0},"cache":{"enabled":true,"ttl_seconds":60,"max_entries":100},"auth":{"enabled":false}}}'

Check "POST /api/v3/ -> 201 Created" {
    (Get-StatusCode "$adminBase/admin/routes" -Method POST -Body $newRoute -Headers $jsonHeaders) -eq 201
}

# ---- CHECK 3: zero downtime — new route works immediately ----
Check "GET /api/v3/ immediately after add -> 200 (zero downtime)" {
    $r = Invoke-WebRequest -Uri "$gatewayBase/api/v3/hello" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    ($r.Content | ConvertFrom-Json).server -eq "upstream-a"
}

# ---- CHECK 4: list now shows 3 routes ----
Check "GET /admin/routes returns 3 routes after add" {
    $r = Invoke-WebRequest -Uri "$adminBase/admin/routes" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    ($r.Content | ConvertFrom-Json).Count -eq 3
}

# ---- CHECK 5: delete route -> 204 ----
Check "DELETE /admin/routes/api/v3/ -> 204 No Content" {
    (Get-StatusCode "$adminBase/admin/routes/api/v3/" -Method DELETE) -eq 204
}

# ---- CHECK 6: deleted route returns 404 ----
Check "GET /api/v3/ after delete -> 404" {
    (Get-StatusCode "$gatewayBase/api/v3/hello") -eq 404
}

# ---- CHECK 7: list back to 2 routes ----
Check "GET /admin/routes returns 2 routes after delete" {
    $r = Invoke-WebRequest -Uri "$adminBase/admin/routes" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    ($r.Content | ConvertFrom-Json).Count -eq 2
}

# ---- CHECK 8: unknown upstream -> 400 ----
$badRoute = '{"path":"/api/v4/","upstream":"nonexistent","plugins":{}}'
Check "POST with unknown upstream -> 400 Bad Request" {
    (Get-StatusCode "$adminBase/admin/routes" -Method POST -Body $badRoute -Headers $jsonHeaders) -eq 400
}

# ---- CHECK 9: update existing route -> 200, behavior changes live ----
# Update /api/v1/ to disable cache; the next GET must have no X-Cache header.
$updatedRoute = '{"path":"/api/v1/","upstream":"service-a","plugins":{"rate_limit":{"enabled":false,"requests_per_second":0,"burst":0},"cache":{"enabled":false,"ttl_seconds":0,"max_entries":0},"auth":{"enabled":false}}}'

Check "POST existing route -> 200 (update, not create)" {
    (Get-StatusCode "$adminBase/admin/routes" -Method POST -Body $updatedRoute -Headers $jsonHeaders) -eq 200
}

Check "Updated /api/v1/ (cache disabled) -> no X-Cache header" {
    $r = Invoke-WebRequest -Uri "$gatewayBase/api/v1/update-test" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    -not $r.Headers.ContainsKey("X-Cache")
}

# ---- SUMMARY ----
Write-Host ""
$color = if ($failed -eq 0) { "Green" } else { "Red" }
Write-Host "=== $passed passed, $failed failed ===" -ForegroundColor $color
Write-Host ""
if ($failed -eq 0) {
    Write-Host "Phase 4 complete. Tell Claude to start Phase 5." -ForegroundColor Green
} else {
    Write-Host "Some checks failed. Share the output above with Claude." -ForegroundColor Red
}
Write-Host ""

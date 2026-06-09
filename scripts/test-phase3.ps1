# test-phase3.ps1
# Runs all Phase 3 verification checks (Auth, RateLimit, Cache).
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

# Returns the HTTP status code of a request, catching non-2xx exceptions.
function Get-StatusCode {
    param([string]$Uri, [hashtable]$Headers = @{}, [string]$Method = "GET")
    try {
        $r = Invoke-WebRequest -Uri $Uri -Method $Method -Headers $Headers `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
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
    if ((Get-StatusCode "http://localhost:8080/api/v1/ping") -in @(200, 401, 429)) {
        $ready = $true; break
    }
    Start-Sleep -Seconds 1
}
if (-not $ready) {
    Write-Host ""
    Write-Host "ERROR: Gateway not responding. Run .\scripts\start-all.ps1 first." -ForegroundColor Red
    exit 1
}
Write-Host "Gateway is up." -ForegroundColor Green

# ============================================================
Write-Host ""
Write-Host "=== Phase 3 Checks ===" -ForegroundColor Cyan

# ---- AUTH ----
Write-Host ""
Write-Host "  -- Auth --" -ForegroundColor DarkCyan

Check "/api/v2/ no credentials -> 401" {
    (Get-StatusCode "http://localhost:8080/api/v2/test") -eq 401
}

Check "/api/v2/ wrong password -> 401" {
    $h = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:wrongpassword")) }
    (Get-StatusCode "http://localhost:8080/api/v2/test" -Headers $h) -eq 401
}

Check "/api/v2/ correct credentials (admin:secret) -> 200" {
    $h = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:secret")) }
    (Get-StatusCode "http://localhost:8080/api/v2/test" -Headers $h) -eq 200
}

Check "/api/v1/ no credentials -> 200 (auth disabled)" {
    (Get-StatusCode "http://localhost:8080/api/v1/test") -eq 200
}

# ---- RATE LIMIT ----
Write-Host ""
Write-Host "  -- Rate Limit (firing 80 parallel requests; burst=20, expect 429s) --" -ForegroundColor DarkCyan

# Use RunspacePool so all 80 requests hit the gateway simultaneously.
# With burst=20 and rps=100, at least 50 of 80 simultaneous requests should get 429.
# Each runspace returns "STATUS|RETRY-AFTER" so we capture both in one burst.
$rlUri = "http://localhost:8080/api/v1/rl-test"
$rlScript = {
    param($u)
    try {
        $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 5
        return "$([int]$r.StatusCode)|"
    } catch {
        $status = try { [int]$_.Exception.Response.StatusCode.value__ } catch { 0 }
        $ra     = try { $_.Exception.Response.Headers["Retry-After"] } catch { "" }
        return "$status|$ra"
    }
}

$pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 80)
$pool.Open()
$runspaces = @()
for ($i = 0; $i -lt 80; $i++) {
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($rlScript).AddArgument($rlUri)
    $runspaces += [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
}
$rlResults = @()
foreach ($rs in $runspaces) {
    $res = $rs.PS.EndInvoke($rs.Handle)
    if ($res.Count -gt 0) { $rlResults += [string]$res[0] }
    $rs.PS.Dispose()
}
$pool.Close()

$count200       = ($rlResults | Where-Object { $_.StartsWith("200") }).Count
$count429       = ($rlResults | Where-Object { $_.StartsWith("429") }).Count
$hasRetryAfter  = ($rlResults | Where-Object { $_ -eq "429|1" }).Count -gt 0
Write-Host "        200s: $count200  |  429s: $count429  (out of $($rlResults.Count) requests)" -ForegroundColor DarkGray

Check "80 parallel requests produce at least 1 rate-limit 429" {
    $count429 -ge 1
}

# Retry-After is checked from the same burst — no timing dependency.
Check "429 response includes Retry-After: 1 header" {
    $hasRetryAfter
}

# ---- CACHE ----
Write-Host ""
Write-Host "  -- Cache --" -ForegroundColor DarkCyan

# Use a unique path so we start with a guaranteed MISS regardless of prior tests.
$cacheKey = "http://localhost:8080/api/v1/cache-test-key-phase3"

Check "First GET -> X-Cache: MISS" {
    $r = Invoke-WebRequest -Uri $cacheKey -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $r.Headers["X-Cache"] -eq "MISS"
}

Check "Second identical GET -> X-Cache: HIT" {
    $r = Invoke-WebRequest -Uri $cacheKey -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $r.Headers["X-Cache"] -eq "HIT"
}

Check "Different URL -> X-Cache: MISS (new key)" {
    $r = Invoke-WebRequest -Uri "http://localhost:8080/api/v1/cache-test-key-phase3-b" `
        -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $r.Headers["X-Cache"] -eq "MISS"
}

Check "POST is never cached (no X-Cache header)" {
    $r = Invoke-WebRequest -Uri $cacheKey -Method POST `
        -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    -not $r.Headers.ContainsKey("X-Cache")
}

Check "/api/v2/ (cache disabled) -> no X-Cache header ever" {
    $h = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:secret")) }
    $r1 = Invoke-WebRequest -Uri "http://localhost:8080/api/v2/cache-test" `
        -Headers $h -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $r2 = Invoke-WebRequest -Uri "http://localhost:8080/api/v2/cache-test" `
        -Headers $h -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    (-not $r1.Headers.ContainsKey("X-Cache")) -and (-not $r2.Headers.ContainsKey("X-Cache"))
}

# ---- SUMMARY ----
Write-Host ""
$color = if ($failed -eq 0) { "Green" } else { "Red" }
Write-Host "=== $passed passed, $failed failed ===" -ForegroundColor $color
Write-Host ""
if ($failed -eq 0) {
    Write-Host "Phase 3 complete. Tell Claude to start Phase 4." -ForegroundColor Green
} else {
    Write-Host "Some checks failed. Share the output above with Claude." -ForegroundColor Red
}
Write-Host ""

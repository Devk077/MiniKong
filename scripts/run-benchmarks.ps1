# run-benchmarks.ps1
# Runs all three Phase 7 benchmarks using hey and prints a copy-paste summary.
# Requires the local stack to be running: .\scripts\start-all.ps1
# Stop Docker containers first (ports must be free).

$gateway = "http://localhost:8080"
$admin   = "http://localhost:9090"

# ---- helpers ----------------------------------------------------------------

function Update-V1([string]$body) {
    Invoke-WebRequest -Uri "$admin/admin/routes" -Method POST -Body $body `
        -ContentType "application/json" -UseBasicParsing -TimeoutSec 5 `
        -ErrorAction Stop | Out-Null
}

function Restore-V1 {
    $orig = '{"path":"/api/v1/","upstream":"service-a","plugins":{"rate_limit":{"enabled":true,"requests_per_second":100.0,"burst":20},"cache":{"enabled":true,"ttl_seconds":30,"max_entries":1000},"auth":{"enabled":false}}}'
    Update-V1 $orig
}

function Parse-P99([string[]]$out) {
    $line = $out | Where-Object { $_ -match '^\s+99%' }
    if ($line -match '([\d.]+) secs') { return [double]$Matches[1] * 1000 }
    return 0
}

function Parse-P50([string[]]$out) {
    $line = $out | Where-Object { $_ -match '^\s+50%' }
    if ($line -match '([\d.]+) secs') { return [double]$Matches[1] * 1000 }
    return 0
}

function Parse-RPS([string[]]$out) {
    $line = $out | Where-Object { $_ -match 'Requests/sec' }
    if ($line -match '([\d.]+)') { return [double]$Matches[1] }
    return 0
}

function Parse-Status([string[]]$out, [int]$code) {
    $line = $out | Where-Object { $_ -match "\[$code\]" }
    if ($line -match '\[' + $code + '\]\s+(\d+)') { return [int]$Matches[1] }
    return 0
}

function Get-Counter([string[]]$lines, [string]$pattern) {
    $line = $lines | Where-Object { $_ -match $pattern } | Select-Object -Last 1
    if (-not $line) { return 0.0 }
    if ($line -match '\}\s+([\d.]+)') { return [double]$Matches[1] }
    return 0.0
}

# ---- 0. prerequisites -------------------------------------------------------

Write-Host ""
Write-Host "=== MiniGateway Phase 7 Benchmarks ===" -ForegroundColor Cyan
Write-Host ""

# Check / install hey
$heyCmd = Get-Command hey -ErrorAction SilentlyContinue
if (-not $heyCmd) {
    Write-Host "hey not found -- installing via go install ..." -ForegroundColor Yellow
    go install github.com/rakyll/hey@latest
    $gobin = (go env GOPATH) + "\bin"
    $env:PATH = "$gobin;$env:PATH"
    $heyCmd = Get-Command hey -ErrorAction SilentlyContinue
    if (-not $heyCmd) {
        Write-Host "ERROR: hey not found after install." -ForegroundColor Red
        Write-Host "       Add $(go env GOPATH)\bin to your PATH and retry." -ForegroundColor Red
        exit 1
    }
}
Write-Host "hey: $($heyCmd.Source)" -ForegroundColor DarkGray

# Check gateway
Write-Host "Checking gateway on :8080 ..." -ForegroundColor Yellow
$ready = $false
for ($i = 0; $i -lt 10; $i++) {
    try {
        Invoke-WebRequest -Uri "$gateway/api/v1/ping" -UseBasicParsing -TimeoutSec 2 `
            -ErrorAction Stop | Out-Null
        $ready = $true; break
    } catch { Start-Sleep -Seconds 1 }
}
if (-not $ready) {
    Write-Host "ERROR: Gateway not responding. Run .\scripts\start-all.ps1 first." -ForegroundColor Red
    exit 1
}
Write-Host "Gateway is up." -ForegroundColor Green
Write-Host ""

# ---- Benchmark A: proxy overhead (no cache, no RL) --------------------------

Write-Host "--- Benchmark A: Proxy Overhead (cache + RL disabled) ---" -ForegroundColor Cyan

$noPlugins = '{"path":"/api/v1/","upstream":"service-a","plugins":{"rate_limit":{"enabled":false,"requests_per_second":0,"burst":0},"cache":{"enabled":false,"ttl_seconds":0,"max_entries":0},"auth":{"enabled":false}}}'
Update-V1 $noPlugins
Write-Host "  Config updated. Running hey -n 5000 -c 50 ..." -ForegroundColor DarkGray

$outA  = & hey -n 5000 -c 50 "$gateway/api/v1/bench-a" 2>&1
$p99A  = Parse-P99 $outA
$p50A  = Parse-P50 $outA
$rpsA  = Parse-RPS $outA

Write-Host "  hey output:" -ForegroundColor DarkGray
$outA | Select-String "Requests/sec|50%|99%|Status code|200|429" | ForEach-Object {
    Write-Host "    $_" -ForegroundColor DarkGray
}

$p50Astr = $p50A.ToString("F2")
$p99Astr = $p99A.ToString("F2")
$rpsAstr = $rpsA.ToString("F0")
Write-Host ""
Write-Host "  RESULT A: p50 = $p50Astr ms | p99 = $p99Astr ms | rps = $rpsAstr" -ForegroundColor White

Restore-V1
Write-Host "  Config restored." -ForegroundColor DarkGray

# ---- Benchmark B: cache hit rate --------------------------------------------

Write-Host ""
Write-Host "--- Benchmark B: Cache Hit Rate (same URL repeated) ---" -ForegroundColor Cyan

$cacheOnly = '{"path":"/api/v1/","upstream":"service-a","plugins":{"rate_limit":{"enabled":false,"requests_per_second":0,"burst":0},"cache":{"enabled":true,"ttl_seconds":30,"max_entries":1000},"auth":{"enabled":false}}}'
Update-V1 $cacheOnly
Write-Host "  Cache enabled, RL disabled. Warming up ..." -ForegroundColor DarkGray
& hey -n 1000 -c 10 "$gateway/api/v1/bench-b-key" 2>&1 | Out-Null

Write-Host "  Running hey -n 10000 -c 50 (same URL) ..." -ForegroundColor DarkGray
$outB = & hey -n 10000 -c 50 "$gateway/api/v1/bench-b-key" 2>&1
$p99B = Parse-P99 $outB
$p50B = Parse-P50 $outB
$rpsB = Parse-RPS $outB

Start-Sleep -Milliseconds 300
$rawM   = (Invoke-WebRequest -Uri "http://localhost:2112/metrics" -UseBasicParsing -TimeoutSec 5).Content
$mlines = $rawM -split "`n"
$hits   = Get-Counter $mlines 'minigateway_cache_hits_total\{route="/api/v1/"\}'
$misses = Get-Counter $mlines 'minigateway_cache_misses_total\{route="/api/v1/"\}'
$total  = $hits + $misses
$hitPct = if ($total -gt 0) { [Math]::Round($hits / $total * 100, 1) } else { 0 }

$upstream = Get-Counter $mlines 'minigateway_upstream_requests_total\{route="/api/v1/"'
$allReqs  = Get-Counter $mlines 'minigateway_request_duration_seconds_count\{route="/api/v1/"'
$loadRed  = if ($allReqs -gt 0) { [Math]::Round((1 - $upstream / $allReqs) * 100, 1) } else { 0 }

Write-Host "  hey output:" -ForegroundColor DarkGray
$outB | Select-String "Requests/sec|50%|99%|Status code|200" | ForEach-Object {
    Write-Host "    $_" -ForegroundColor DarkGray
}

$p50Bstr     = $p50B.ToString("F2")
$p99Bstr     = $p99B.ToString("F2")
$rpsBstr     = $rpsB.ToString("F0")
$hitPctStr   = $hitPct.ToString("F1")
$loadRedStr  = $loadRed.ToString("F1")
Write-Host ""
Write-Host "  RESULT B: hit rate = $hitPctStr% | upstream load reduction = $loadRedStr%" -ForegroundColor White
Write-Host "            p50 = $p50Bstr ms | p99 = $p99Bstr ms | rps = $rpsBstr" -ForegroundColor White

Restore-V1
Write-Host "  Config restored." -ForegroundColor DarkGray

# ---- Benchmark C: rate limit enforcement ------------------------------------

Write-Host ""
Write-Host "--- Benchmark C: Rate Limit Enforcement (50 rps, burst 5) ---" -ForegroundColor Cyan

$lowRL = '{"path":"/api/v1/","upstream":"service-a","plugins":{"rate_limit":{"enabled":true,"requests_per_second":50.0,"burst":5},"cache":{"enabled":false,"ttl_seconds":0,"max_entries":0},"auth":{"enabled":false}}}'
Update-V1 $lowRL
Write-Host "  RL set to 50 rps / burst 5. Running hey -n 1000 -c 100 ..." -ForegroundColor DarkGray

$outC   = & hey -n 1000 -c 100 "$gateway/api/v1/bench-c" 2>&1
$ok200  = Parse-Status $outC 200
$rej429 = Parse-Status $outC 429

Write-Host "  hey output:" -ForegroundColor DarkGray
$outC | Select-String "Requests/sec|Status code|200|429" | ForEach-Object {
    Write-Host "    $_" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  RESULT C: 200 OK = $ok200 | 429 Rejected = $rej429" -ForegroundColor White

Restore-V1
Write-Host "  Config restored." -ForegroundColor DarkGray

# ---- Summary ----------------------------------------------------------------

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  BENCHMARK SUMMARY (copy to Claude)" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  A. Proxy overhead (no plugins, 5000 req, c=50):"
Write-Host "     p50 = $p50Astr ms | p99 = $p99Astr ms | rps = $rpsAstr"
Write-Host ""
Write-Host "  B. Cache hit rate (same URL, 10000 req, c=50):"
Write-Host "     Hit rate = $hitPctStr%   Upstream load reduction = $loadRedStr%"
Write-Host "     p50 = $p50Bstr ms | p99 = $p99Bstr ms | rps = $rpsBstr"
Write-Host ""
Write-Host "  C. Rate limit (50 rps, burst 5, 1000 req, c=100):"
Write-Host "     200 OK = $ok200   429 Rejected = $rej429"
Write-Host ""
Write-Host "Share this output with Claude to generate the README." -ForegroundColor Yellow
Write-Host ""

#Requires -Version 7
<#
r770-site-shot.ps1 - one screenshot of one lab page through the rehearsal tunnel.
Operator PC only. Starts a private headless browser whose resolver maps the
three .lab names to 127.0.0.1, so the system hosts file is never edited.

  -Browser     path to msedge.exe or chrome.exe
  -TunnelPort  the local port `r770-staging-vm.sh tunnel` listens on
  -Url         https://malcolm.lab:<port>/..., gns3.lab or docs.lab only
  -Out         absolute path of the PNG to write
  -AuthFile    optional: a file holding user:password on one line. It is sent
               as a Basic Authorization header ONLY on requests to https,
               malcolm.lab / gns3.lab / docs.lab, on the tunnel port; the
               value never reaches a command line, the output, or the
               screenshot's file name.

Every request the page makes goes through the DevTools Fetch domain: a request
to the three names on the tunnel port is allowed (with the header when
-AuthFile was given), the browser's own internal about:/data:/chrome-error:
URLs are allowed without it, and every other request is failed, never sent -
with or without -AuthFile. Unknown host names also do not resolve. Every wait
is bounded; on a timeout the script throws and the browser is cleaned up.

Certificate errors are ignored here on purpose: the certificate is checked
separately, with a TLS client against the lab CA.
Prints {"status":..,"title":..,"url":..} for the page it captured.
#>
param(
    [Parameter(Mandatory)][string]$Browser,
    [Parameter(Mandatory)][int]$TunnelPort,
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Out,
    [string]$AuthFile,
    [int]$WaitSeconds = 10
)
$ErrorActionPreference = 'Stop'
$names = 'malcolm.lab', 'gns3.lab', 'docs.lab'
$target = [uri]$Url
if ($target.Scheme -ne 'https' -or $names -notcontains $target.Host -or $target.Port -ne $TunnelPort) {
    throw "Url must be https://<$($names -join '|')>:$TunnelPort/..."
}
if (-not [IO.Path]::IsPathRooted($Out)) { throw "-Out must be an absolute path" }
if (-not (Test-Path -LiteralPath $Browser)) { throw "no browser at $Browser" }

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start(); $debugPort = $listener.LocalEndpoint.Port; $listener.Stop()
$profileDir = Join-Path ([IO.Path]::GetTempPath()) ("r770-shot-" + [guid]::NewGuid().ToString('N'))
$rules = (($names | ForEach-Object { "MAP $_ 127.0.0.1" }) + 'MAP * ~NOTFOUND') -join ', '
$browserArgs = @(
    '--headless=new', "--remote-debugging-port=$debugPort", "--user-data-dir=`"$profileDir`"",
    "--host-resolver-rules=`"$rules`"", '--ignore-certificate-errors', '--window-size=1440,900',
    '--no-first-run', '--disable-extensions', '--disable-site-isolation-trials', 'about:blank'
)
$proc = Start-Process -FilePath $Browser -ArgumentList $browserArgs -PassThru
$ws = $null
$script:cdpId = 0
$script:recv = $null
$script:buf = [byte[]]::new(1048576)
$script:msg = [IO.MemoryStream]::new()
$script:basic = $null

# 'lab' = the tunnel's names (gets the login), 'internal' = browser-own URL
# (allowed, never gets the login), 'blocked' = everything else.
function Get-UrlKind([string]$u) {
    try { $x = [uri]$u } catch { return 'blocked' }
    if ($x.Scheme -eq 'https' -and $names -contains $x.Host -and $x.Port -eq $TunnelPort) { return 'lab' }
    if (@('about', 'data', 'chrome-error') -contains $x.Scheme) { return 'internal' }
    return 'blocked'
}

function Send-Cdp([string]$Method, [hashtable]$Params = @{}) {
    $script:cdpId++
    $json = @{ id = $script:cdpId; method = $Method; params = $Params } | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $send = $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None)
    if (-not $send.Wait(10000)) { throw "${Method}: the browser did not accept the command within 10 seconds" }
    return $script:cdpId
}

# One pending receive is kept and polled; it is never cancelled (a cancelled
# receive aborts the socket). Returns one parsed message, or $null on timeout.
function Receive-Cdp([int]$Ms) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Ms)
    while ($true) {
        if (-not $script:recv) {
            $script:recv = $ws.ReceiveAsync([ArraySegment[byte]]::new($script:buf), [Threading.CancellationToken]::None)
        }
        $left = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $script:recv.Wait($left)) { return $null }
        $part = $script:recv.Result
        $script:recv = $null
        if ($part.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw "the browser closed the debugging connection" }
        $script:msg.Write($script:buf, 0, $part.Count)
        if ($part.EndOfMessage) {
            $text = [Text.Encoding]::UTF8.GetString($script:msg.ToArray())
            $script:msg.SetLength(0)
            return ($text | ConvertFrom-Json)
        }
    }
}

# Answer every paused request at once: continue (allowed) or fail (blocked).
function Resolve-Event($m) {
    if ($m.method -ne 'Fetch.requestPaused') { return }
    $rid = $m.params.requestId
    $kind = Get-UrlKind $m.params.request.url
    if ($kind -eq 'blocked') {
        $null = Send-Cdp 'Fetch.failRequest' @{ requestId = $rid; errorReason = 'BlockedByClient' }
    } elseif ($kind -eq 'lab' -and $script:basic) {
        $hdrs = @($m.params.request.headers.PSObject.Properties |
            Where-Object { $_.Name -ne 'Authorization' } |
            ForEach-Object { @{ name = $_.Name; value = [string]$_.Value } })
        $hdrs += @{ name = 'Authorization'; value = "Basic $script:basic" }
        $null = Send-Cdp 'Fetch.continueRequest' @{ requestId = $rid; headers = $hdrs }
    } else {
        $null = Send-Cdp 'Fetch.continueRequest' @{ requestId = $rid }
    }
}

function Invoke-Cdp([string]$Method, [hashtable]$Params = @{}) {
    $id = Send-Cdp $Method $Params
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($true) {
        $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($left -le 0) { throw "${Method}: no reply from the browser within 30 seconds" }
        $reply = Receive-Cdp $left
        if (-not $reply) { throw "${Method}: no reply from the browser within 30 seconds" }
        if ($reply.method) { Resolve-Event $reply; continue }
        if ($reply.id -eq $id) {
            if ($reply.error) { throw "${Method}: $($reply.error.message)" }
            return $reply.result
        }
    }
}

# Keep answering events for $Seconds.
function Invoke-Pump([int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $left = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $m = Receive-Cdp ([Math]::Min($left, 250))
        if ($m -and $m.method) { Resolve-Event $m }
    }
}

try {
    $page = $null
    foreach ($try in 1..30) {
        try {
            $page = (Invoke-RestMethod "http://127.0.0.1:$debugPort/json/list" -TimeoutSec 2) | Where-Object { $_.type -eq 'page' -and $_.url -eq 'about:blank' } | Select-Object -First 1
        } catch { $page = $null }
        if ($page) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $page) { throw "the browser's debugging port did not answer" }

    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $connect = $ws.ConnectAsync([uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None)
    if (-not $connect.Wait(10000)) { throw "the browser's debugging socket did not open within 10 seconds" }

    if ($AuthFile) {
        $pair = (Get-Content -LiteralPath $AuthFile -Raw).Trim()
        if ($pair -notmatch '^[^:]+:.+$') { throw "AuthFile does not hold user:password" }
        $script:basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    }
    $null = Invoke-Cdp 'Fetch.enable' @{ patterns = @(@{ urlPattern = '*' }) }
    $nav = Invoke-Cdp 'Page.navigate' @{ url = $Url }
    # A server that answered 401 or an empty 4xx/5xx is a result to report (its
    # status is read below); anything else (no route, refused, blocked) is a failure.
    $answered = 'net::ERR_INVALID_AUTH_CREDENTIALS', 'net::ERR_HTTP_RESPONSE_CODE_FAILURE'
    if ($nav.errorText -and $answered -notcontains $nav.errorText) { throw "navigation failed: $($nav.errorText)" }
    Invoke-Pump $WaitSeconds
    $expr = "JSON.stringify({status:(performance.getEntriesByType('navigation')[0]||{}).responseStatus,title:document.title,url:location.href})"
    $info = Invoke-Cdp 'Runtime.evaluate' @{ expression = $expr; returnByValue = $true }
    $shot = Invoke-Cdp 'Page.captureScreenshot' @{ format = 'png' }
    [IO.File]::WriteAllBytes($Out, [Convert]::FromBase64String($shot.data))
    $info.result.value
}
finally {
    if ($ws) { $ws.Dispose() }
    if ($proc -and -not $proc.HasExited) { & taskkill /PID $proc.Id /T /F *> $null }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
}

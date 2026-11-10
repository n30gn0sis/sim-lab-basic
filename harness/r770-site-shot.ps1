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
               as a Basic Authorization header; the value never reaches a
               command line, the output, or the screenshot's file name.

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
$rules = ($names | ForEach-Object { "MAP $_ 127.0.0.1" }) -join ', '
$browserArgs = @(
    '--headless=new', "--remote-debugging-port=$debugPort", "--user-data-dir=`"$profileDir`"",
    "--host-resolver-rules=`"$rules`"", '--ignore-certificate-errors', '--window-size=1440,900',
    '--no-first-run', '--disable-extensions', 'about:blank'
)
$proc = Start-Process -FilePath $Browser -ArgumentList $browserArgs -PassThru
$ws = $null
$script:cdpId = 0

function Invoke-Cdp([string]$Method, [hashtable]$Params = @{}) {
    $script:cdpId++
    $json = @{ id = $script:cdpId; method = $Method; params = $Params } | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $none = [Threading.CancellationToken]::None
    $null = $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $none).GetAwaiter().GetResult()
    $buffer = [byte[]]::new(1048576)
    while ($true) {
        $stream = [IO.MemoryStream]::new()
        do {
            $part = $ws.ReceiveAsync([ArraySegment[byte]]::new($buffer), $none).GetAwaiter().GetResult()
            $stream.Write($buffer, 0, $part.Count)
        } until ($part.EndOfMessage)
        $reply = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
        if ($reply.id -eq $script:cdpId) {
            if ($reply.error) { throw "${Method}: $($reply.error.message)" }
            return $reply.result
        }
    }
}

try {
    $page = $null
    foreach ($try in 1..30) {
        try {
            $page = (Invoke-RestMethod "http://127.0.0.1:$debugPort/json/list") | Where-Object { $_.type -eq 'page' -and $_.url -eq 'about:blank' } | Select-Object -First 1
        } catch { $page = $null }
        if ($page) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $page) { throw "the browser's debugging port did not answer" }

    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $null = $ws.ConnectAsync([uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    $null = Invoke-Cdp 'Network.enable'
    if ($AuthFile) {
        $pair = (Get-Content -LiteralPath $AuthFile -Raw).Trim()
        if ($pair -notmatch '^[^:]+:.+$') { throw "AuthFile does not hold user:password" }
        $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
        $null = Invoke-Cdp 'Network.setExtraHTTPHeaders' @{ headers = @{ Authorization = "Basic $basic" } }
    }
    $null = Invoke-Cdp 'Page.navigate' @{ url = $Url }
    Start-Sleep -Seconds $WaitSeconds
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

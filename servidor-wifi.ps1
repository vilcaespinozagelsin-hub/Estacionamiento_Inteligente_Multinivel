$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot)
$port = 8766
$statePath = Join-Path $root 'parking-state.local.json'
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $port)

function Get-StateEnvelope {
  if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { return Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  }
  return [pscustomobject]@{ revision = 0; state = $null }
}

function Send-Response($stream, [string]$status, [string]$contentType, [byte[]]$body, [bool]$headOnly = $false) {
  $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Type: $contentType`r`nContent-Length: $($body.Length)`r`nConnection: close`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`n`r`n")
  $stream.Write($header, 0, $header.Length)
  if (-not $headOnly -and $body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
  $stream.Flush()
}

function Send-Json($stream, [string]$status, $value) {
  $json = ConvertTo-Json -InputObject $value -Compress -Depth 20
  Send-Response $stream $status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

$listener.Start()
try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $headerBuilder = [Text.StringBuilder]::new()
      $tail = ''
      while ($true) {
        $nextByte = $stream.ReadByte()
        if ($nextByte -lt 0) { break }
        $char = [char]$nextByte
        [void]$headerBuilder.Append($char)
        $tail += $char
        if ($tail.Length -gt 4) { $tail = $tail.Substring($tail.Length - 4) }
        if ($tail -eq "`r`n`r`n") { break }
        if ($headerBuilder.Length -gt 16384) { break }
      }
      $headerLines = $headerBuilder.ToString() -split "`r`n"
      $requestParts = $headerLines[0] -split ' ', 3
      if ($requestParts.Length -lt 2) { continue }
      $method = $requestParts[0].ToUpperInvariant()
      $requestUri = [Uri]::new("http://localhost$($requestParts[1])")
      $path = [Uri]::UnescapeDataString($requestUri.AbsolutePath)
      $headers = @{}
      foreach ($line in ($headerLines | Select-Object -Skip 1)) {
        if ($line -match '^([^:]+):\s*(.*)$') { $headers[$Matches[1].ToLowerInvariant()] = $Matches[2].Trim() }
      }
      $contentLength = 0
      if ($headers.ContainsKey('content-length')) { [void][int]::TryParse($headers['content-length'], [ref]$contentLength) }
      if ($contentLength -lt 0 -or $contentLength -gt 1048576) { Send-Json $stream '413 Payload Too Large' @{ error = 'Solicitud demasiado grande.' }; continue }
      $requestBody = [byte[]]::new($contentLength)
      $offset = 0
      while ($offset -lt $contentLength) { $read = $stream.Read($requestBody, $offset, $contentLength - $offset); if ($read -le 0) { break }; $offset += $read }
      if ($offset -ne $contentLength) { Send-Json $stream '400 Bad Request' @{ error = 'Solicitud incompleta.' }; continue }

      if ($path -eq '/api/health' -and $method -eq 'GET') { Send-Json $stream '200 OK' @{ ok = $true }; continue }
      if ($path -eq '/api/state') {
        if ($method -eq 'GET') { Send-Json $stream '200 OK' (Get-StateEnvelope); continue }
        if ($method -ne 'POST') { Send-Json $stream '405 Method Not Allowed' @{ error = 'Método no permitido.' }; continue }
        if (-not $headers.ContainsKey('origin') -or -not $headers.ContainsKey('host') -or ([Uri]::new($headers['origin']).Authority -ne $headers['host'])) { Send-Json $stream '403 Forbidden' @{ error = 'Origen no autorizado.' }; continue }
        try { $payload = [Text.Encoding]::UTF8.GetString($requestBody) | ConvertFrom-Json } catch { Send-Json $stream '400 Bad Request' @{ error = 'Estado JSON inválido.' }; continue }
        $state = $payload.state
        if (-not $state -or $state.spaces.Count -ne 60 -or $state.queue.Count -gt 200 -or $state.activity.Count -gt 2000) { Send-Json $stream '400 Bad Request' @{ error = 'Estado incompleto o fuera de límites.' }; continue }
        $validState = $true
        $allowed = @('free','occupied','reserved','blocked')
        for ($i = 0; $i -lt 60; $i++) { if ([int]$state.spaces[$i].id -ne ($i + 1) -or $state.spaces[$i].state -notin $allowed) { $validState = $false; break } }
        if (-not $validState) { Send-Json $stream '400 Bad Request' @{ error = 'La distribución de espacios no es válida.' }; continue }
        if (@($state.spaces | Where-Object { $_.state -eq 'blocked' }).Count -gt 10) { Send-Json $stream '400 Bad Request' @{ error = 'Bloqueo máximo 10: no se permiten más espacios bloqueados.' }; continue }
        $current = Get-StateEnvelope
        if ([int]$payload.revision -ne [int]$current.revision) { Send-Json $stream '409 Conflict' $current; continue }
        $next = [pscustomobject]@{ revision = ([int]$current.revision + 1); state = $state }
        $serialized = ConvertTo-Json -InputObject $next -Compress -Depth 20
        [IO.File]::WriteAllText($statePath, $serialized, [Text.UTF8Encoding]::new($false))
        Send-Json $stream '200 OK' $next
        continue
      }
      if ($path -eq '/api/print-ticket') {
        if ($method -ne 'POST') { Send-Json $stream '405 Method Not Allowed' @{ error = 'Método no permitido.' }; continue }
        if (-not $headers.ContainsKey('origin') -or -not $headers.ContainsKey('host') -or ([Uri]::new($headers['origin']).Authority -ne $headers['host'])) { Send-Json $stream '403 Forbidden' @{ error = 'Origen no autorizado.' }; continue }
        if ($contentLength -lt 1 -or $contentLength -gt 24000) { Send-Json $stream '413 Payload Too Large' @{ error = 'Boleto no válido.' }; continue }
        try {
          $printBody = [Text.Encoding]::UTF8.GetString($requestBody)
          $result = Invoke-RestMethod -Uri 'http://127.0.0.1:8765/api/print-ticket' -Method Post -ContentType 'application/json; charset=utf-8' -Headers @{ Origin = 'http://127.0.0.1:8765' } -Body ([Text.Encoding]::UTF8.GetBytes($printBody)) -TimeoutSec 25
          Send-Json $stream '200 OK' @{ ok = $true; duplicate = [bool]$result.duplicate; status = [string]$result.status }
        } catch { Send-Json $stream '503 Service Unavailable' @{ error = 'No está activa la central de impresión de la computadora.' } }
        continue
      }
      if ($method -notin @('GET','HEAD')) { Send-Json $stream '405 Method Not Allowed' @{ error = 'Método no permitido.' }; continue }
      if ($path -eq '/') { $path = '/index.html' }
      $publicFiles = @('/index.html','/app.js','/styles.css','/roles.css','/assets/parking-background.jpg')
      if ($path -notin $publicFiles) { Send-Json $stream '404 Not Found' @{ error = 'No encontrado.' }; continue }
      $filePath = [IO.Path]::GetFullPath((Join-Path $root $path.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar)))
      $safeRoot = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
      if (-not $filePath.StartsWith($safeRoot,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) { Send-Json $stream '404 Not Found' @{ error = 'No encontrado.' }; continue }
      $type = switch ([IO.Path]::GetExtension($filePath).ToLowerInvariant()) { '.html' { 'text/html; charset=utf-8' } '.js' { 'text/javascript; charset=utf-8' } '.css' { 'text/css; charset=utf-8' } '.jpg' { 'image/jpeg' } default { 'application/octet-stream' } }
      Send-Response $stream '200 OK' $type ([IO.File]::ReadAllBytes($filePath)) ($method -eq 'HEAD')
    } catch { try { Send-Json $stream '500 Internal Server Error' @{ error = 'Error interno del servidor local.' } } catch { } }
    finally { $client.Dispose() }
  }
} finally { $listener.Stop() }

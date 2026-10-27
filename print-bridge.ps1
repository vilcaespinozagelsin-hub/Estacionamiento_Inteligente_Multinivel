$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $root 'print-bridge.local.json'
$listener = [Net.HttpListener]::new()
$prefix = 'http://127.0.0.1:8765/'
$listener.Prefixes.Add($prefix)

function Send-Json($context, [int]$status, $value) {
  $bytes = [Text.Encoding]::UTF8.GetBytes(($value | ConvertTo-Json -Compress -Depth 5))
  $context.Response.StatusCode = $status
  $context.Response.ContentType = 'application/json; charset=utf-8'
  $context.Response.Headers['Cache-Control'] = 'no-store'
  $context.Response.Headers['X-Content-Type-Options'] = 'nosniff'
  $context.Response.ContentLength64 = $bytes.Length
  $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $context.Response.Close()
}

function Safe-Text($value, [int]$limit = 200) {
  $text = [string]$value
  $text = $text -replace '[\r\n\x00-\x1f]', ' '
  if ($text.Length -gt $limit) { $text = $text.Substring(0, $limit) }
  return $text.Trim()
}

function Get-MimeType([string]$path) {
  switch ([IO.Path]::GetExtension($path).ToLowerInvariant()) {
    '.html' { return 'text/html; charset=utf-8' }
    '.js' { return 'text/javascript; charset=utf-8' }
    '.css' { return 'text/css; charset=utf-8' }
    '.jpg' { return 'image/jpeg' }
    '.jpeg' { return 'image/jpeg' }
    '.png' { return 'image/png' }
    '.svg' { return 'image/svg+xml' }
    default { return 'application/octet-stream' }
  }
}

if (-not (Test-Path -LiteralPath $configPath)) { throw 'Falta print-bridge.local.json. Vuelve a ejecutar iniciar-impresion.bat para configurar la conexión.' }
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
foreach ($key in @('api_jobs_url', 'site_access_token', 'submit_token')) {
  if ([string]::IsNullOrWhiteSpace([string]$config.$key)) { throw "Falta el ajuste local requerido: $key" }
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$rootPrefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
$listener.Start()

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      $request = $context.Request
      $path = [Uri]::UnescapeDataString($request.Url.AbsolutePath)
      if ($path -eq '/health') {
        Send-Json $context 200 @{ ok = $true; bridge = 'VILCA local' }
        continue
      }
      if ($path -eq '/api/print-ticket') {
        if ($request.HttpMethod -ne 'POST') { Send-Json $context 405 @{ error = 'Método no permitido.' }; continue }
        if ($request.Headers['Origin'] -ne 'http://127.0.0.1:8765') { Send-Json $context 403 @{ error = 'Origen local no autorizado.' }; continue }
        if ($request.ContentLength64 -lt 1 -or $request.ContentLength64 -gt 24000) { Send-Json $context 413 @{ error = 'El boleto enviado no es válido.' }; continue }
        $reader = [IO.StreamReader]::new($request.InputStream, [Text.Encoding]::UTF8)
        $body = $reader.ReadToEnd() | ConvertFrom-Json
        $source = Safe-Text $body.source 80
        $externalId = Safe-Text $body.external_id 100
        $title = Safe-Text $body.title 120
        $content = [string]$body.content
        $copies = [int]$body.copies
        if (-not $source -or -not $externalId -or -not $title -or -not $content -or $content.Length -gt 8000 -or $copies -lt 1 -or $copies -gt 3) {
          Send-Json $context 400 @{ error = 'Faltan datos requeridos o exceden el límite permitido.' }
          continue
        }
        $job = @{ source = $source; external_id = $externalId; title = $title; content = $content; copies = $copies } | ConvertTo-Json -Compress -Depth 4
        $headers = @{
          'OAI-Sites-Authorization' = "Bearer $($config.site_access_token)"
          'Authorization' = "Bearer $($config.submit_token)"
        }
        try {
          $result = Invoke-RestMethod -Uri $config.api_jobs_url -Method Post -ContentType 'application/json; charset=utf-8' -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($job)) -TimeoutSec 20
          Send-Json $context 200 @{ ok = $true; duplicate = [bool]$result.duplicate; id = [string]$result.job.id; status = [string]$result.job.status }
        } catch {
          Send-Json $context 502 @{ error = 'La central no recibió el boleto. Revisa la conexión y vuelve a intentar.' }
        }
        continue
      }
      if ($request.HttpMethod -ne 'GET' -and $request.HttpMethod -ne 'HEAD') { Send-Json $context 405 @{ error = 'Método no permitido.' }; continue }
      if ($path -eq '/') { $path = '/index.html' }
      $publicFiles = @('/index.html','/app.js','/styles.css','/roles.css','/assets/parking-background.jpg')
      if ($publicFiles -notcontains $path) { Send-Json $context 404 @{ error = 'No encontrado.' }; continue }
      $relative = $path.TrimStart('/').Replace('/', '\')
      $filePath = [IO.Path]::GetFullPath((Join-Path $root $relative))
      if (-not $filePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Send-Json $context 404 @{ error = 'No encontrado.' }
        continue
      }
      $bytes = [IO.File]::ReadAllBytes($filePath)
      $context.Response.StatusCode = 200
      $context.Response.ContentType = Get-MimeType $filePath
      $context.Response.Headers['X-Content-Type-Options'] = 'nosniff'
      $context.Response.ContentLength64 = $bytes.Length
      if ($request.HttpMethod -ne 'HEAD') { $context.Response.OutputStream.Write($bytes, 0, $bytes.Length) }
      $context.Response.Close()
    } catch {
      try { Send-Json $context 500 @{ error = 'Error interno del puente local.' } } catch { }
    }
  }
} finally {
  $listener.Stop()
  $listener.Close()
}

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverUrl = 'http://127.0.0.1:8766/'
$connected = $false
function Test-Port([int]$port) { try { $tcp=[Net.Sockets.TcpClient]::new(); $tcp.Connect('127.0.0.1',$port); $tcp.Dispose(); return $true } catch { return $false } }
if (-not (Test-Port 8766)) {
  $server = Join-Path $root 'servidor-wifi.ps1'
  Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',("`"$server`""))
  for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Milliseconds 300; if (Test-Port 8766) { $connected = $true; break } }
} else { $connected = $true }
if (-not $connected) { Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show('No se pudo iniciar VILCA Wi-Fi. Comprueba si el puerto 8766 está ocupado.','VILCA') | Out-Null; exit 1 }
if ((Test-Path -LiteralPath (Join-Path $root 'print-bridge.local.json')) -and -not (Test-Port 8765)) {
  $printer = Join-Path $root 'print-bridge.ps1'
  Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',("`"$printer`""))
}
Start-Process $serverUrl

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$url = 'http://127.0.0.1:8765/'
try { Invoke-RestMethod -Uri ($url + 'health') -TimeoutSec 2 | Out-Null } catch {
  $server = Join-Path $root 'print-bridge.ps1'
  Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',("`"$server`"")) -WindowStyle Hidden
  $ready = $false
  for ($i=0; $i -lt 25; $i++) { Start-Sleep -Milliseconds 400; try { Invoke-RestMethod -Uri ($url + 'health') -TimeoutSec 1 | Out-Null; $ready=$true; break } catch { } }
  if (-not $ready) { Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show('No se pudo iniciar la central local de impresión. Comprueba que el puerto 8765 esté libre.','VILCA - Impresión') | Out-Null; exit 1 }
}
& (Join-Path $root 'iniciar-wifi.ps1')

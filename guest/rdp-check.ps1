# rdp-check.ps1 - did RDP sessions use the NVIDIA hardware H.264 encoder?
# Looks for RdpCoreTS events 162 (client graphics caps) and 170 (AVC hardware encoder).
# Exit: 0 = event 170 with an NVIDIA encoder found, 1 = not found (connect a NEW RDP session first).
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$log = 'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational'
$ev = @(Get-WinEvent -LogName $log -MaxEvents 1000 -ErrorAction SilentlyContinue | Where-Object { $_.Id -in 162, 170 } | Select-Object -First 6)
foreach ($e in $ev) { '{0}  Id={1}  {2}' -f $e.TimeCreated, $e.Id, ($e.Message -replace '\s+', ' ') }

$hw = $ev | Where-Object { $_.Id -eq 170 -and $_.Message -match 'NVIDIA' } | Select-Object -First 1
if ($hw) { 'RDP_HW_ENCODER=NVIDIA ({0})' -f $hw.TimeCreated; exit 0 }
'RDP_HW_ENCODER=not seen - open a NEW RDP session (policies apply to new sessions only) and run again'
exit 1

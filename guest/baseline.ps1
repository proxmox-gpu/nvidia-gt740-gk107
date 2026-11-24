# baseline.ps1 - first configuration of a fresh Windows guest (run via the guest agent as SYSTEM):
# report OS/network/devices, enable RDP (language independent), small crash dumps.
# Exit: 0 = RDP enabled and listening, 1 = otherwise.
param([int]$CrashDump = 3)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$os = Get-CimInstance Win32_OperatingSystem
'== OS'
'Caption     : {0}' -f $os.Caption
'Version     : {0} (build {1})' -f $os.Version, $os.BuildNumber
'UI language : {0}' -f ($os.MUILanguages -join ',')
'Computer    : {0}' -f $env:COMPUTERNAME
'Last boot   : {0}' -f $os.LastBootUpTime
$c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
'C: free     : {0:N1} GiB of {1:N1} GiB' -f ($c.FreeSpace / 1GB), ($c.Size / 1GB)

'== Network (IPv4)'
Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -ne '127.0.0.1' | ForEach-Object {
  '{0,-30} {1}/{2} {3}' -f $_.InterfaceAlias, $_.IPAddress, $_.PrefixLength, $_.PrefixOrigin
}

'== Devices with problems'
$probs = @(Get-PnpDevice -PresentOnly | Where-Object Status -ne 'OK')
if ($probs.Count -eq 0) { 'none' } else {
  $probs | ForEach-Object { '{0,-8} {1} [{2}]' -f $_.Status, $_.FriendlyName, $_.InstanceId }
}

'== QEMU guest agent'
(Get-Service QEMU-GA | Select-Object -ExpandProperty Status)

'== Enabling Remote Desktop'
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
# Rule names are the same in every UI language (DisplayGroup is localized)
Enable-NetFirewallRule -Name RemoteDesktop-UserMode-In-TCP, RemoteDesktop-UserMode-In-UDP
Set-Service TermService -StartupType Automatic
Start-Service TermService

'== Crash dump mode -> {0} (3 = small dump, fast reboot while debugging; 7 = automatic)' -f $CrashDump
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name CrashDumpEnabled -Value $CrashDump

$deny = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections
$rules = Get-NetFirewallRule -Name RemoteDesktop-UserMode-In-TCP, RemoteDesktop-UserMode-In-UDP
$svc = Get-Service TermService
$listen = @(Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue).Count -gt 0
'fDenyTSConnections : {0}' -f $deny
$rules | ForEach-Object { '{0,-30}: Enabled={1}' -f $_.Name, $_.Enabled }
'TermService        : {0} / {1}' -f $svc.Status, $svc.StartType
'Listening on 3389  : {0}' -f $listen

if ($deny -eq 0 -and $svc.Status -eq 'Running' -and $listen) { exit 0 }
exit 1

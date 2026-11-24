# diag-gpu.ps1 - read-only diagnostics of the passed-through NVIDIA card in the guest,
# aimed at "device cannot start" problems (Code 43 = CM_PROB_FAILED_POST_START, Code 10, Code 31):
# OS build, hypervisor flag, every NVIDIA function with its problem code / problem status,
# driver package, display adapters, nvlddmkm service, recent nvlddmkm / Kernel-PnP / Display
# events and the last setupapi install section for the card.
# Exit: always 0 (diagnostics only), 2 = no NVIDIA devices.
param([int]$EventHours = 24)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

function Section($t) { ''; "## $t" }

Section 'OS'
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
'Caption          : {0}' -f $os.Caption
'Build            : {0}' -f $os.BuildNumber
'Last boot        : {0}' -f $os.LastBootUpTime
'HypervisorPresent: {0}' -f $cs.HypervisorPresent

Section 'NVIDIA PCI functions'
$devs = @(Get-PnpDevice -PresentOnly | Where-Object InstanceId -like 'PCI\VEN_10DE*')
if ($devs.Count -eq 0) {
  'NO_NVIDIA_DEVICES: no PCI\VEN_10DE* devices present (is hostpci0 attached?)'
  exit 2
}
$keys = 'DEVPKEY_Device_ProblemCode', 'DEVPKEY_Device_ProblemStatus', 'DEVPKEY_Device_DriverVersion',
        'DEVPKEY_Device_DriverDate', 'DEVPKEY_Device_DriverInfPath', 'DEVPKEY_Device_DriverProvider',
        'DEVPKEY_Device_LocationInfo', 'DEVPKEY_Device_LocationPaths', 'DEVPKEY_Device_Parent'
foreach ($d in $devs) {
  '----'
  'Name             : {0}' -f $d.FriendlyName
  'Status / Problem : {0} / {1}' -f $d.Status, $d.Problem
  $p = @{}
  foreach ($r in @(Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName $keys -ErrorAction SilentlyContinue)) {
    $p[$r.KeyName] = $r.Data
  }
  'ProblemCode      : {0}' -f $p['DEVPKEY_Device_ProblemCode']
  $ps = $p['DEVPKEY_Device_ProblemStatus']
  if ($null -ne $ps) { 'ProblemStatus    : 0x{0:X8}' -f ([uint32]([int64]$ps -band 0xFFFFFFFF)) }
  'Driver           : {0} {1} ({2}, {3})' -f $p['DEVPKEY_Device_DriverProvider'], $p['DEVPKEY_Device_DriverVersion'],
                                             $p['DEVPKEY_Device_DriverInfPath'], $p['DEVPKEY_Device_DriverDate']
  'Location         : {0}' -f $p['DEVPKEY_Device_LocationInfo']
  'LocationPaths    : {0}' -f (@($p['DEVPKEY_Device_LocationPaths']) -join '; ')
  'Parent           : {0}' -f $p['DEVPKEY_Device_Parent']
  'InstanceId       : {0}' -f $d.InstanceId
}

Section 'Display adapters (Win32_VideoController)'
Get-CimInstance Win32_VideoController | ForEach-Object {
  '{0} | status={1} | cm_error={2} | driver={3} | pnp={4}' -f $_.Name, $_.Status, $_.ConfigManagerErrorCode,
    $_.DriverVersion, $_.PNPDeviceID
}

Section 'nvlddmkm service'
$svc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm' -ErrorAction SilentlyContinue
if ($svc) {
  'Start            : {0}' -f $svc.Start
  'ImagePath        : {0}' -f $svc.ImagePath
  $drv = Get-CimInstance Win32_SystemDriver -Filter "Name='nvlddmkm'" -ErrorAction SilentlyContinue
  if ($drv) { 'State            : {0}' -f $drv.State }
} else {
  'nvlddmkm service not present (driver not installed)'
}

$since = (Get-Date).AddHours(-$EventHours)
function Show-Events($filter, $title, $max, $match = '') {
  Section "$title (last $EventHours h, newest first)"
  $ev = @(Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue |
    Where-Object { -not $match -or $_.Message -match $match } | Select-Object -First $max)
  if ($ev.Count -eq 0) { 'none'; return }
  foreach ($e in $ev) {
    $msg = ($e.Message -replace '\s+', ' ')
    if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) + '...' }
    '{0:yyyy-MM-dd HH:mm:ss} id={1} {2}: {3}' -f $e.TimeCreated, $e.Id, $e.ProviderName, $msg
  }
}
Show-Events @{ LogName = 'System'; ProviderName = 'nvlddmkm'; StartTime = $since } 'nvlddmkm events' 20
# 400/410 = device configured/started, 411 = device had a problem starting (shows the status code)
Show-Events @{ LogName = 'Microsoft-Windows-Kernel-PnP/Configuration'; Id = 400, 410, 411; StartTime = $since } 'Kernel-PnP events for NVIDIA' 30 'VEN_10DE'
Show-Events @{ LogName = 'System'; ProviderName = 'Display'; StartTime = $since } 'Display events (TDR)' 10
Show-Events @{ LogName = 'System'; Id = 1001; StartTime = $since } 'Bugchecks (System 1001)' 5

Section 'setupapi.dev.log - last install section for the GPU'
$log = Join-Path $env:windir 'INF\setupapi.dev.log'
if (Test-Path $log) {
  $lines = Get-Content $log
  $start = -1
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lines[$i] -match '^>>>\s+\[' -and $lines[$i] -match 'VEN_10DE&DEV_0FC8') { $start = $i; break }
  }
  if ($start -lt 0) {
    'no section for VEN_10DE&DEV_0FC8'
  } else {
    $sel = for ($i = $start; $i -lt $lines.Count; $i++) {
      $lines[$i]
      if ($i -gt $start -and $lines[$i] -match '^<<<\s+\[Exit status') { break }
    }
    # headers and exit status always; warnings/errors without the file-queue cleanup noise
    # ("flq: DeleteFile: FAILED" + "Error 2/3" for temp files that are already gone)
    $sel | Where-Object { $_ -match '^(>>>|<<<)' }
    $issues = @($sel | Where-Object { $_ -match '^!' -and $_ -notmatch 'flq:' })
    'warnings/errors (without flq): {0}' -f $issues.Count
    $issues | Select-Object -Last 40
  }
} else {
  'setupapi.dev.log not found'
}
exit 0

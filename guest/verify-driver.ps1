# verify-driver.ps1 - checks after the reboot that follows the driver install:
# nvidia-smi, recent bugchecks, driver service, crash dump mode, RDP policies.
# Exit: 0 = all checks passed, 1 = at least one failed.
param([int]$BugcheckMinutes = 30)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$fail = 0
$os = Get-CimInstance Win32_OperatingSystem
'Last boot        : {0}' -f $os.LastBootUpTime

# nvidia-smi: the Standard driver keeps it only in the DriverStore (not in PATH)
$smi = @(Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository\nv_*.inf_amd64_*\nvidia-smi.exe' -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending) + @(Get-Item 'C:\Windows\System32\nvidia-smi.exe' -ErrorAction SilentlyContinue)
$smi = $smi | Where-Object { $_ } | Select-Object -First 1
if ($smi) {
  # PowerShell 5.1 turns native stderr into a terminating error under 'Stop'
  $ErrorActionPreference = 'Continue'
  $out = & $smi.FullName --query-gpu=name,driver_version,vbios_version,memory.total,pstate,driver_model.current --format=csv,noheader 2>&1
  $ErrorActionPreference = 'Stop'
  'nvidia-smi       : {0}' -f (($out | ForEach-Object { "$_" }) -join ' ')
  if ($LASTEXITCODE -ne 0) { $fail++ }
} else {
  'nvidia-smi       : NOT FOUND'
  $fail++
}

# BugCheck events (System 1001 from WER-SystemErrorReporting) in the last N minutes
$since = (Get-Date).AddMinutes(-$BugcheckMinutes)
$bc = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; StartTime = $since } -ErrorAction SilentlyContinue |
  Where-Object ProviderName -like '*WER-SystemErrorReporting*')
'Bugchecks {0,3} min: {1}' -f $BugcheckMinutes, $bc.Count
foreach ($e in $bc) { '  {0}  {1}' -f $e.TimeCreated, ($e.Message -replace '\s+', ' ') }
if ($bc.Count -gt 0) { $fail++ }

$svc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm' -ErrorAction SilentlyContinue
'nvlddmkm Start   : {0}' -f $(if ($svc) { $svc.Start } else { 'service missing' })
if (-not $svc -or $svc.Start -ne 3) { $fail++ }

'CrashDumpEnabled : {0}' -f (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl').CrashDumpEnabled

$pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction SilentlyContinue
foreach ($n in 'bEnumerateHWBeforeSW', 'AVC444ModePreferred', 'AVCHardwareEncodePreferred') {
  $v = if ($pol) { $pol.$n } else { $null }
  '{0,-27}: {1}' -f $n, $v
  if ($v -ne 1) { $fail++ }
}

if ($fail -gt 0) { 'VERIFY: {0} check(s) failed' -f $fail; exit 1 }
'VERIFY: OK'
exit 0

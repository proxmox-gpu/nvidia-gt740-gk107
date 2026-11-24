# rdp-policies.ps1 - Remote Desktop hardware acceleration policies (local GPO equivalent):
#   Use hardware graphics adapters for all RDS sessions        -> bEnumerateHWBeforeSW=1
#   Prioritize H.264/AVC 444 graphics mode                      -> AVC444ModePreferred=1
#   Configure H.264/AVC hardware encoding                       -> AVCHardwareEncodePreferred=1
# Applies to NEW RDP sessions. Exit: 0 = all values set.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$want = [ordered]@{ bEnumerateHWBeforeSW = 1; AVC444ModePreferred = 1; AVCHardwareEncodePreferred = 1 }

New-Item -Path $k -Force | Out-Null
foreach ($name in $want.Keys) {
  New-ItemProperty -Path $k -Name $name -PropertyType DWord -Value $want[$name] -Force | Out-Null
}

# gpupdate prints localized OEM-encoded text - discard it, report the exit code only
$ErrorActionPreference = 'Continue'
& gpupdate.exe /target:computer /force /wait:120 *> $null
$ErrorActionPreference = 'Stop'
'gpupdate exitcode: {0}' -f $LASTEXITCODE

$bad = 0
$cur = Get-ItemProperty -Path $k
foreach ($name in $want.Keys) {
  '{0,-27}: {1}' -f $name, $cur.$name
  if ($cur.$name -ne $want[$name]) { $bad++ }
}
if ($bad -gt 0) { exit 1 }
exit 0

# enable-msi.ps1 - set MSISupported=1 on every NVIDIA PCI function (present and phantom).
# Without MSI the Kepler driver runs on INTx inside a VM and the guest falls into a
# BSOD 0x116 VIDEO_TDR_FAILURE loop. The NVIDIA installer may delete the value, so
# this must be re-applied after every driver install/upgrade, before the reboot.
# Exit: 0 = all present functions have MSISupported=1, 1 = otherwise, 2 = no devices.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$all = @(Get-PnpDevice | Where-Object InstanceId -like 'PCI\VEN_10DE*')
if ($all.Count -eq 0) { 'NO_NVIDIA_DEVICES'; exit 2 }

$bad = 0
foreach ($d in $all) {
  $k = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
  New-Item -Path $k -Force | Out-Null
  New-ItemProperty -Path $k -Name MSISupported -PropertyType DWord -Value 1 -Force | Out-Null
  $v = (Get-ItemProperty -Path $k).MSISupported
  $tag = if ($d.Present) { 'present' } else { 'phantom' }
  '{0,-8} {1}: MSISupported={2}  [{3}]' -f $tag, $d.FriendlyName, $v, $d.InstanceId
  if ($d.Present -and $v -ne 1) { $bad++ }
}
if ($bad -gt 0) { exit 1 }
exit 0

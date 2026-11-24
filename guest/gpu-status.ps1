# gpu-status.ps1 - state of all NVIDIA PCI functions in the guest:
# PnP status/problem, MSI flag, IRQ (MSI = IRQ number >= 0x80000000), InstanceId.
# -Strict: exit 1 unless every present function is OK, has MSISupported=1 and an MSI IRQ.
# Exit: 0 = devices found (and healthy with -Strict), 1 = -Strict check failed, 2 = no NVIDIA devices.
param([switch]$Strict)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$devs = @(Get-PnpDevice -PresentOnly | Where-Object InstanceId -like 'PCI\VEN_10DE*')
if ($devs.Count -eq 0) {
  'NO_NVIDIA_DEVICES: no PCI\VEN_10DE* devices present (is hostpci0 attached?)'
  exit 2
}

$alloc = @(Get-CimInstance Win32_PnPAllocatedResource)
$bad = 0

foreach ($d in $devs) {
  $id = $d.InstanceId
  $msiKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$id\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
  $msi = (Get-ItemProperty -Path $msiKey -Name MSISupported -ErrorAction SilentlyContinue).MSISupported
  if ($null -eq $msi) { $msi = 'absent' }

  $irqs = foreach ($a in $alloc) {
    $dev = $a.Dependent.CimInstanceProperties['DeviceID']
    $irq = $a.Antecedent.CimInstanceProperties['IRQNumber']
    if ($dev -and $irq -and $dev.Value -eq $id) {
      $n = [int64]$irq.Value
      if ($n -lt 0) { $n += 4294967296 }
      if ($n -ge 0x80000000) { "$n(MSI)" } else { "$n(INTx)" }
    }
  }
  if (-not $irqs) { $irqs = @('none') }
  if ($d.Status -ne 'OK' -or $msi -ne 1 -or -not ($irqs -match 'MSI')) { $bad++ }

  '----'
  'Name        : {0}' -f $d.FriendlyName
  'Status      : {0}' -f $d.Status
  'Problem     : {0}' -f $d.Problem
  'MSISupported: {0}' -f $msi
  'IRQ         : {0}' -f ($irqs -join ', ')
  'InstanceId  : {0}' -f $id
}
if ($Strict -and $bad -gt 0) { '----'; 'STRICT: {0} function(s) not OK / without MSI' -f $bad; exit 1 }
exit 0

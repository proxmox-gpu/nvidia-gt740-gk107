# nvidia-precheck.ps1 - is an NVIDIA display driver already installed in the guest?
# If it is, attaching the card would start the driver without MSI -> BSOD loop.
# Prints DRIVER_PRESENT=0|1 and the service start type. Exit 0 always.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$svc = 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm'
if (Test-Path $svc) {
  'DRIVER_PRESENT=1'
  'nvlddmkm Start={0}' -f (Get-ItemProperty $svc).Start
} else {
  'DRIVER_PRESENT=0'
}
exit 0

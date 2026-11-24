# run-installer.ps1 - run the NVIDIA installer silently WITHOUT reboot and store its exit
# code in <Dir>\install-rc.txt. Started detached by the host, which polls the rc file.
# Exit codes of the installer: 0 = OK, 1 = OK, reboot pending; anything else = failure.
param(
  [Parameter(Mandatory = $true)][string]$Dir,
  [Parameter(Mandatory = $true)][string]$FileName,
  [ValidateSet('full', 'driver-only')][string]$Mode = 'full',
  [switch]$Clean
)
$ErrorActionPreference = 'Stop'

$rc = Join-Path $Dir 'install-rc.txt'
Remove-Item -Path $rc -ErrorAction SilentlyContinue

if ($Mode -eq 'driver-only') {
  $setup = Join-Path $Dir 'extracted\setup.exe'
  $argList = @('Display.Driver', '-s', '-noreboot', '-noeula', '-nofinish')
} else {
  $setup = Join-Path $Dir $FileName
  $argList = @('-s', '-noreboot')
}
# -clean = "Perform a clean installation": previous NVIDIA driver and settings are removed
# first; needed to replace an installed driver by another (also older) version
if ($Clean) { $argList += '-clean' }

Set-Content -Path (Join-Path $Dir 'install-start.txt') -Value (Get-Date -Format o) -Encoding ascii
try {
  $p = Start-Process -FilePath $setup -ArgumentList $argList -Wait -PassThru
  $code = $p.ExitCode
} catch {
  $code = 'EXCEPTION ' + $_.Exception.Message
}
Set-Content -Path $rc -Value $code -Encoding ascii

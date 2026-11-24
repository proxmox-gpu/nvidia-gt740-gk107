# dump-vbios.ps1 - save the full VBIOS of the NVIDIA card with nvflash (read only, never flashes).
# nvflash reads the EEPROM through the card's own registers, so it works even when the
# PCI ROM BAR returns a truncated image and when the display driver is in Code 43.
# Steps: copy nvflash from the CD labelled $Label, check its Authenticode signature (NVIDIA),
# "nvflash64 --list", "nvflash64 --save". If the save fails while the display function is
# enabled, the function is disabled with pnputil for the read and enabled again afterwards.
# The ROM is also written as base64 (<Out>.b64) so the host can fetch it via agent file-read.
# Exit: 0 = saved, 2 = CD/nvflash not found, 3 = signature not valid, 4 = no adapter listed,
#       5 = save failed, 6 = saved file is not a ROM.
param(
  [Parameter(Mandatory = $true)][string]$Label,
  [Parameter(Mandatory = $true)][string]$Dest,
  [string]$Out = 'vbios-nvflash.rom',
  [switch]$AllowUnsigned
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$vol = Get-Volume | Where-Object FileSystemLabel -eq $Label | Select-Object -First 1
if (-not $vol -or -not $vol.DriveLetter) { "CD_NOT_FOUND: no CD volume labelled $Label"; exit 2 }
$src = '{0}:\' -f $vol.DriveLetter
$dir = Join-Path $Dest 'nvflash'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item -Path (Join-Path $src '*') -Destination $dir -Recurse -Force
$exe = Join-Path $dir 'nvflash64.exe'
if (-not (Test-Path $exe)) { "NVFLASH_NOT_FOUND: nvflash64.exe is not on $src"; exit 2 }
'nvflash      : {0}' -f $exe
'SHA256       : {0}' -f (Get-FileHash $exe -Algorithm SHA256).Hash

$sig = Get-AuthenticodeSignature $exe
'Signature    : {0}' -f $sig.Status
'Signer       : {0}' -f $sig.SignerCertificate.Subject
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=NVIDIA Corporation') {
  if ($AllowUnsigned) { 'WARNING: signature not valid/NVIDIA - continuing because of -AllowUnsigned' }
  else { 'SIGNATURE_NOT_VALID: nvflash64.exe is not validly signed by NVIDIA'; exit 3 }
}

# native tools: stderr must not become a terminating error
function Run-Nvflash([string[]]$a) {
  $ErrorActionPreference = 'Continue'
  $o = & $exe @a 2>&1 | ForEach-Object { "$_" }
  $script:rc = $LASTEXITCODE
  $o | ForEach-Object { '  | ' + $_ }
  'exit code    : {0}' -f $script:rc
}

''
'== nvflash64 --list'
Run-Nvflash @('--list')
if ($rc -ne 0) { 'NO_ADAPTER: nvflash --list failed'; exit 4 }

$rom = Join-Path $Dest $Out
Remove-Item $rom, "$rom.b64" -Force -ErrorAction SilentlyContinue

''
'== nvflash64 --save'
Run-Nvflash @('--save', $rom)
if ($rc -ne 0 -or -not (Test-Path $rom)) {
  $gpu = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\VEN_10DE*' -and $_.Class -eq 'Display' } |
    Select-Object -First 1
  if (-not $gpu) { 'SAVE_FAILED: no NVIDIA display function to disable for a retry'; exit 5 }
  ''
  '== retry with the display function disabled: {0}' -f $gpu.InstanceId
  $ErrorActionPreference = 'Continue'
  try {
    & pnputil.exe /disable-device $gpu.InstanceId 2>&1 | ForEach-Object { '  | ' + $_ }
    Run-Nvflash @('--save', $rom)
  } finally {
    & pnputil.exe /enable-device $gpu.InstanceId 2>&1 | ForEach-Object { '  | ' + $_ }
  }
  $ErrorActionPreference = 'Stop'
  if ($rc -ne 0 -or -not (Test-Path $rom)) { 'SAVE_FAILED: nvflash --save failed'; exit 5 }
}

$bytes = [IO.File]::ReadAllBytes($rom)
''
'ROM file     : {0} ({1} bytes)' -f $rom, $bytes.Length
'ROM SHA256   : {0}' -f (Get-FileHash $rom -Algorithm SHA256).Hash
# nvflash dumps may start with a vendor header; the option ROM (0x55AA) follows it.
# Only a sanity check here - the host (lib/rom_check.py) locates and validates the images.
$hex = [BitConverter]::ToString($bytes, 0, [Math]::Min(16, $bytes.Length))
'First bytes  : {0}' -f $hex
$found = $false
for ($i = 0; $i -lt $bytes.Length - 1; $i++) { if ($bytes[$i] -eq 0x55 -and $bytes[$i + 1] -eq 0xAA) { $found = $true; break } }
if ($bytes.Length -lt 512 -or -not $found) { 'NOT_A_ROM: no 0x55AA header anywhere in the file'; exit 6 }
'0x55AA at    : 0x{0:X}' -f $i
[IO.File]::WriteAllText("$rom.b64", [Convert]::ToBase64String($bytes), [Text.Encoding]::ASCII)
'BASE64       : {0}.b64' -f $rom
exit 0

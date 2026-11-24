# prepare-driver.ps1 - copy the NVIDIA installer from the driver ISO, verify SHA256 and
# the Authenticode signature. The NVIDIA installer validates its own signature; on newer
# Windows builds the Entrust.net (2048) timestamping root may be missing -> TRUST_E_TIME_STAMP.
# Exit: 0 = ready, 2 = ISO not found, 3 = Entrust root missing (host adds it),
#       4 = signature invalid for another reason, 5 = hash mismatch.
param(
  [Parameter(Mandatory = $true)][string]$Label,
  [Parameter(Mandatory = $true)][string]$FileName,
  [Parameter(Mandatory = $true)][string]$Sha256,
  [Parameter(Mandatory = $true)][string]$Dest,
  [ValidateSet('full', 'driver-only')][string]$Mode = 'full'
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$EntrustRoot = '503006091D97D4F5AE39F7CBE7927D7D652D3431'   # Entrust.net Certification Authority (2048)

$vol = Get-Volume | Where-Object FileSystemLabel -eq $Label | Select-Object -First 1
if (-not $vol -or -not $vol.DriveLetter) { "ISO_NOT_FOUND: no CD volume labelled $Label"; exit 2 }
$src = '{0}:\' -f $vol.DriveLetter
'driver ISO  : {0}' -f $src

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$exe = Join-Path $Dest $FileName
$want = $Sha256.ToUpperInvariant()
if (-not (Test-Path $exe) -or (Get-FileHash $exe -Algorithm SHA256).Hash -ne $want) {
  Copy-Item -Path (Join-Path $src $FileName) -Destination $exe -Force
}
$hash = (Get-FileHash $exe -Algorithm SHA256).Hash
'SHA256      : {0}' -f $hash
if ($hash -ne $want) { "HASH_MISMATCH: expected $want"; exit 5 }

if ($Mode -eq 'driver-only') {
  $ex = Join-Path $Dest 'extracted'
  if (-not (Test-Path (Join-Path $ex 'setup.exe'))) {
    Copy-Item -Path (Join-Path $src 'extracted') -Destination $Dest -Recurse -Force
  }
  if (-not (Test-Path (Join-Path $ex 'setup.exe'))) { 'EXTRACTED_SETUP_NOT_FOUND'; exit 2 }
  'extracted   : {0}' -f $ex
}

$sig = Get-AuthenticodeSignature $exe
'Signature   : {0}' -f $sig.Status
'Signer      : {0}' -f $sig.SignerCertificate.Subject
'TimeStamper : {0}' -f $sig.TimeStamperCertificate.Subject
if ($sig.Status -eq 'Valid') { 'SIGNATURE_OK'; exit 0 }

if ($sig.TimeStamperCertificate) {
  $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
  $chain.ChainPolicy.RevocationMode = 'NoCheck'
  [void]$chain.Build($sig.TimeStamperCertificate)
  foreach ($el in $chain.ChainElements) { '  chain: {0} | {1}' -f $el.Certificate.Thumbprint, $el.Certificate.Subject }
  foreach ($st in $chain.ChainStatus) { '  status: {0}' -f $st.Status }
}
if (-not (Test-Path "Cert:\LocalMachine\Root\$EntrustRoot")) {
  'NEED_ENTRUST_ROOT: timestamping root {0} is not in LocalMachine\Root' -f $EntrustRoot
  exit 3
}
'SIGNATURE_INVALID'
exit 4

# encoding-test.ps1 - prints localized strings so the host can check that
# non-ASCII guest output (e.g. Cyrillic) is decoded correctly.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

'ascii line      : OK'
'culture         : {0}' -f (Get-Culture).Name
'OS caption      : {0}' -f (Get-CimInstance Win32_OperatingSystem).Caption
# Built-in Administrators group: its name is localized (e.g. Russian UI)
'admins group    : {0}' -f (Get-LocalGroup -SID 'S-1-5-32-544').Name
'users group     : {0}' -f (Get-LocalGroup -SID 'S-1-5-32-545').Name
exit 0

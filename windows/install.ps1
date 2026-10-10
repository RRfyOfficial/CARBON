# CARBON Companion: build one self-contained .exe and install it for the current user (no admin).
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1 [-NoStart]
# Installs to %LOCALAPPDATA%\Programs\CARBON Companion, adds a Start menu shortcut, and starts it.
# The installed app registers itself to launch at login (switch it off in its panel).
# Uninstall: turn off LAUNCH AT LOGIN in the panel, quit, then delete that folder and the shortcut.
param([switch]$NoStart)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$publish = Join-Path $root 'publish'
$target = Join-Path $env:LOCALAPPDATA 'Programs\CARBON Companion'
$exe = Join-Path $target 'CARBON Companion.exe'

# One instance at a time, and a running copy would lock the file.
Get-Process -Name 'CARBON Companion' -ErrorAction SilentlyContinue | Stop-Process -Force

dotnet publish (Join-Path $root 'src\Carbon.Companion\Carbon.Companion.csproj') `
    -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -o $publish -v q -nologo
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }

New-Item -ItemType Directory -Force $target | Out-Null
Copy-Item (Join-Path $publish 'CARBON Companion.exe') $exe -Force

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'CARBON Companion.lnk'))
$shortcut.TargetPath = $exe
$shortcut.WorkingDirectory = $target
$shortcut.Description = 'CARBON Companion: text scanned with your glasses lands here'
$shortcut.Save()

Write-Host "Installed: $exe"
Write-Host 'Start menu: CARBON Companion'
if (-not $NoStart) { Start-Process $exe }

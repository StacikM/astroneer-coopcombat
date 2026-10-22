# CoopCombat installer / updater. Double-click Install-or-Update.bat (it runs this).
# - finds the Astroneer folder by itself (Steam)
# - installs from the "payload" folder next to this script, or, if update_url.txt has a link, downloads the latest version
# - keeps a backup of the old mod and keeps any other UE4SS mods the user already has
param(
    [string]$GameDir = "",
    [switch]$NoPause,
    [switch]$NoShortcut
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Finish([int]$code) {
    if (-not $NoPause) { Write-Host ""; Read-Host "Press Enter to close" | Out-Null }
    exit $code
}

function Find-Win64 {
    $libs = @()
    $steam = $null
    try { $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction Stop).SteamPath } catch { }
    if ($steam) {
        $libs += $steam
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' -AllMatches)) {
                foreach ($g in $m.Matches) { $libs += ($g.Groups[1].Value -replace '\\\\', '\') }
            }
        }
    }
    $libs += "C:\Program Files (x86)\Steam"
    foreach ($l in ($libs | Select-Object -Unique)) {
        $p = Join-Path $l "steamapps\common\ASTRONEER\Astro\Binaries\Win64"
        if (Test-Path (Join-Path $p "Astro-Win64-Shipping.exe")) { return $p }
    }
    return $null
}

function Read-Version([string]$file) {
    if (Test-Path $file) { return (Get-Content $file -Raw).Trim() }
    return $null
}

Write-Host "=== CoopCombat installer / updater ===" -ForegroundColor Cyan

# 1. find the game
$win64 = $GameDir
if (-not $win64) { $win64 = Find-Win64 }
if (-not $win64) {
    Write-Host "Could not find Astroneer automatically."
    Write-Host "In Steam: right-click ASTRONEER > Manage > Browse local files, open Astro\Binaries\Win64, copy that path."
    $win64 = (Read-Host "Paste the Win64 folder path here").Trim('"', ' ')
}
if (-not (Test-Path (Join-Path $win64 "Astro-Win64-Shipping.exe"))) {
    Write-Host "That folder doesn't contain Astro-Win64-Shipping.exe: $win64" -ForegroundColor Red
    Finish 1
}
Write-Host "Game folder: $win64"

# 2. the game must be closed (it locks the mod files)
while (Get-Process -Name "Astro-Win64-Shipping" -ErrorAction SilentlyContinue) {
    Write-Host "Astroneer is running. Close it, then press Enter." -ForegroundColor Yellow
    if ($NoPause) { Write-Host "Astroneer is running." -ForegroundColor Red; Finish 1 }
    Read-Host | Out-Null
}

$modDir = Join-Path $win64 "ue4ss\Mods\CoopCombat"
$installedVersion = Read-Version (Join-Path $modDir "version.txt")

# 3. where do the files come from?
$src = $null
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("coopcombat-" + [guid]::NewGuid().ToString("N"))
$base = $null
$urlFile = Join-Path $here "update_url.txt"
if (Test-Path $urlFile) {
    $line = (Get-Content $urlFile | Where-Object { $_.Trim() -ne "" -and -not $_.Trim().StartsWith("#") } | Select-Object -First 1)
    if ($line) { $base = $line.Trim().TrimEnd("/") }
}
$payload = Join-Path $here "payload"

if ($base) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Host "Checking for updates..."
        $latest = (Invoke-WebRequest -UseBasicParsing -Uri "$base/version.txt").Content.Trim()
        if ($installedVersion -and $installedVersion -eq $latest) {
            Write-Host "Already up to date (version $latest)." -ForegroundColor Green
            Finish 0
        }
        Write-Host "Downloading version $latest ..."
        New-Item -ItemType Directory -Path $tempRoot | Out-Null
        $zip = Join-Path $tempRoot "update.zip"
        Invoke-WebRequest -UseBasicParsing -Uri "$base/CoopCombat-update.zip" -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath (Join-Path $tempRoot "x") -Force
        $src = Join-Path $tempRoot "x\payload"
    } catch {
        Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Yellow
        if (Test-Path $payload) { Write-Host "Using the files that came with this installer instead." }
    }
}
if (-not $src) { $src = $payload }
if (-not (Test-Path (Join-Path $src "dwmapi.dll"))) {
    Write-Host "No mod files found to install (the 'payload' folder is missing)." -ForegroundColor Red
    Finish 1
}
$newVersion = Read-Version (Join-Path $src "ue4ss\Mods\CoopCombat\version.txt")

# 4. back up the old mod, then copy everything except the mod lists (those are merged below)
if (Test-Path $modDir) {
    $bak = $modDir + ".backup"
    if (Test-Path $bak) { Remove-Item $bak -Recurse -Force }
    Copy-Item $modDir $bak -Recurse -Force
}
Get-ChildItem -Path $src -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length).TrimStart("\")
    if ($rel -ieq "ue4ss\Mods\mods.txt" -or $rel -ieq "ue4ss\Mods\mods.json") { return }
    $dest = Join-Path $win64 $rel
    $dir = Split-Path -Parent $dest
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item $_.FullName $dest -Force
}

# 5. make sure CoopCombat is enabled in the mod lists without touching other mods
$txt = Join-Path $win64 "ue4ss\Mods\mods.txt"
$json = Join-Path $win64 "ue4ss\Mods\mods.json"
if (Test-Path $txt) {
    $t = [System.IO.File]::ReadAllText($txt)
    if ($t -match "(?m)^CoopCombat\s*:\s*\d") {
        $t = [regex]::Replace($t, "(?m)^CoopCombat\s*:\s*\d", "CoopCombat : 1")
    } elseif ($t -match "(?m)^; Built-in keybinds") {
        $t = [regex]::Replace($t, "(?m)^; Built-in keybinds", "CoopCombat : 1`r`n`r`n; Built-in keybinds", 1)
    } else {
        $t = $t.TrimEnd() + "`r`nCoopCombat : 1`r`n"
    }
    [System.IO.File]::WriteAllText($txt, $t)
} else {
    Copy-Item (Join-Path $src "ue4ss\Mods\mods.txt") $txt -Force
}
if (Test-Path $json) {
    # PowerShell 5.1 hands a JSON array back as one object; piping it through ForEach-Object unrolls it
    $list = @(Get-Content $json -Raw | ConvertFrom-Json | ForEach-Object { $_ })
    $found = $false
    foreach ($m in $list) { if ($m.mod_name -eq "CoopCombat") { $m.mod_enabled = $true; $found = $true } }
    if (-not $found) { $list += [pscustomobject]@{ mod_name = "CoopCombat"; mod_enabled = $true } }
    ConvertTo-Json -InputObject $list -Depth 4 | Set-Content $json -Encoding UTF8
} else {
    Copy-Item (Join-Path $src "ue4ss\Mods\mods.json") $json -Force
}

# 6. keep a copy of the updater next to the mod, and put a shortcut on the desktop
$updaterDir = Join-Path $modDir "updater"
New-Item -ItemType Directory -Path $updaterDir -Force | Out-Null
# when we downloaded, the newest installer script is in the downloaded zip; otherwise it's the one running now
$installerRoot = $here
if (Test-Path (Join-Path $tempRoot "x\install.ps1")) { $installerRoot = Join-Path $tempRoot "x" }
foreach ($f in @("Install-or-Update.bat", "install.ps1", "update_url.txt")) {
    $from = Join-Path $installerRoot $f
    $dest = Join-Path $updaterDir $f
    if (-not (Test-Path $from)) { continue }
    if (Test-Path $dest) {
        if ($f -ne "install.ps1") { continue }  # never replace the running .bat or the saved update link
        if ((Get-FileHash $from).Hash -eq (Get-FileHash $dest).Hash) { continue }
    }
    Copy-Item $from $dest -Force
}
if (-not $NoShortcut) {
    try {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $sh = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $desktop "Update CoopCombat.lnk"))
        $sh.TargetPath = Join-Path $updaterDir "Install-or-Update.bat"
        $sh.WorkingDirectory = $updaterDir
        $sh.Save()
    } catch { Write-Host "(couldn't create the desktop shortcut, not a problem)" }
}

if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }

if ($installedVersion) { Write-Host "Updated $installedVersion -> $newVersion" -ForegroundColor Green }
else { Write-Host "Installed version $newVersion" -ForegroundColor Green }
Write-Host "Done. Start Astroneer from Steam. Next time, use the 'Update CoopCombat' shortcut on your desktop."
Finish 0

<#
  build.ps1 - Offline build of a bootable, driver-included qcow2 from a Win11 ARM64 ISO + drivers.
  No Setup, no qemu boot: DISM apply-image + offline driver injection (no signature prompt) + bcdboot + bcdedit.
  First boot runs OOBE via unattend to create USER/autologon (non-interactive).

  Requirements: x64 Windows (Administrator); built-in dism/bcdboot/diskpart; qemu-img (QEMU for Windows, on PATH).
  Config: config.ps1 next to this script (copy from config.example.ps1) sets $SRC_ISO / $DRIVERS_DIR / ...
  Usage: run as Administrator, or  powershell -ExecutionPolicy Bypass -File build.ps1
  Cross-arch note: x64 host applying/injecting an ARM64 image + bcdboot usually works; if not, use ARM64 Windows/WinPE.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

# --- Command echo helpers: print the command before executing it ---
function Format-CommandArg([AllowNull()][object]$Arg) {
    if ($null -eq $Arg) { return "''" }
    $s = [string]$Arg
    if ($s -eq '') { return "''" }
    if ($s -match '^[A-Za-z0-9_./:\\=-]+$') { return $s }
    return "'" + ($s -replace "'", "''") + "'"
}

function Format-CommandLine([string]$Command, [object[]]$Arguments = @()) {
    $parts = @((Format-CommandArg $Command))
    foreach ($a in $Arguments) { $parts += (Format-CommandArg $a) }
    return ($parts -join ' ')
}

function Show-CommandLine([string]$Command, [object[]]$Arguments = @()) {
    Write-Host ("> " + (Format-CommandLine $Command $Arguments)) -ForegroundColor DarkCyan
}


# --- Requires Administrator (diskpart/dism/bcdboot/mount all need it) ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Administrator required, relaunching elevated..." -ForegroundColor Yellow
    Show-CommandLine "Start-Process" @("powershell", "-ExecutionPolicy Bypass -File `"$PSCommandPath`"", "-Verb", "RunAs")
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$HERE = $PSScriptRoot
$ROOT = Split-Path $HERE -Parent

# --- Load config.ps1 (PowerShell's native "source .env": dot-source a script that sets the
#     $SRC_ISO / $DRIVERS_DIR / ... variables). Copy config.example.ps1 -> config.ps1 and edit.
#     Precedence (resolved below): environment variable / CLI  >  config.ps1  >  built-in default. ---
$cfgFile = Join-Path $HERE "config.ps1"
if (Test-Path $cfgFile) { . $cfgFile }

# --- Helpers ---
# Native commands (diskpart/dism/bcdboot/bcdedit/qemu-img) do NOT honor $ErrorActionPreference,
# so a non-zero exit is otherwise silently swallowed by "| Out-Null". Call this right after them.
function Assert-Exit([string]$what) {
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit code $LASTEXITCODE)" }
}

function Invoke-ExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [object[]]$ArgumentList = @(),
        [switch]$OutNull,
        [string]$What = ''
    )

    Show-CommandLine $FilePath $ArgumentList
    if ($OutNull) {
        & $FilePath @ArgumentList | Out-Null
    }
    else {
        & $FilePath @ArgumentList
    }

    if ($What) { Assert-Exit $What }
}

function Invoke-DiskPartScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [switch]$OutNull
    )

    Show-CommandLine "diskpart" @("/s", $Path)
    Write-Host "> diskpart script:" -ForegroundColor DarkCyan
    Get-Content $Path | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor DarkCyan }

    if ($OutNull) {
        & diskpart /s $Path | Out-Null
    }
    else {
        & diskpart /s $Path
    }
}


# Pick a drive letter that is genuinely free. "Free" must also exclude letters that are merely
# RESERVED in MountedDevices (left behind by a previously detached VHDX) - diskpart refuses to
# 'assign' those with "The specified drive letter is not free to be assigned", even though no
# volume currently shows them.
function Get-FreeDriveLetter([string[]]$Exclude = @()) {
    $used = New-Object System.Collections.Generic.HashSet[string]
    foreach ($l in (Get-Volume -ErrorAction SilentlyContinue).DriveLetter) { if ($l) { [void]$used.Add("$l".ToUpper()) } }
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name) { if ($d.Length -eq 1) { [void]$used.Add($d.ToUpper()) } }
    try {
        $md = Get-Item 'HKLM:\SYSTEM\MountedDevices' -ErrorAction SilentlyContinue
        if ($md) { foreach ($p in $md.Property) { if ($p -match '^\\DosDevices\\([A-Z]):$') { [void]$used.Add($Matches[1]) } } }
    } catch {}
    foreach ($e in $Exclude) { [void]$used.Add("$e".ToUpper()) }
    foreach ($c in @('W', 'X', 'Y', 'Z', 'V', 'U', 'T', 'S', 'R', 'Q', 'P', 'N', 'M', 'L', 'K', 'J', 'H', 'G')) {
        if (-not $used.Contains($c)) { return $c }
    }
    throw "no free drive letter available"
}

# Resolve the install.wim image index. IMAGE_INDEX <= 0 -> list editions and let the user pick.
# Uses Get-WindowsImage (native objects: ImageIndex/ImageName/ImageSize) - no text parsing.
function Resolve-ImageIndex([string]$wim, [int]$wanted) {
    Show-CommandLine "Get-WindowsImage" @("-ImagePath", $wim)
    $images = @(Get-WindowsImage -ImagePath $wim)
    $valid = @($images | ForEach-Object { [int]$_.ImageIndex })
    if ($wanted -gt 0) {
        if ($valid -notcontains $wanted) {
            throw ("IMAGE_INDEX=$wanted not in this ISO. Available: " +
                (($images | ForEach-Object { "$($_.ImageIndex)=$($_.ImageName)" }) -join ', '))
        }
        return $wanted
    }
    if ($images.Count -eq 1) {
        Write-Host "[image] one edition only -> index $($valid[0]) ($($images[0].ImageName))"
        return $valid[0]
    }
    Write-Host "`nEditions in install.wim:" -ForegroundColor Cyan
    foreach ($im in $images) {
        Write-Host ("  [{0}] {1}  ({2:N1} GB)" -f $im.ImageIndex, $im.ImageName, ($im.ImageSize / 1GB))
    }
    if ([Console]::IsInputRedirected) {
        throw ("IMAGE_INDEX not set and no interactive console. Set IMAGE_INDEX to one of: " + ($valid -join ', '))
    }
    do {
        $sel = (Read-Host "`nSelect image index").Trim()
        $n = 0
        $ok = [int]::TryParse($sel, [ref]$n) -and ($valid -contains $n)
        if (-not $ok) { Write-Host ("  invalid, choose from: " + ($valid -join ', ')) -ForegroundColor DarkYellow }
    } while (-not $ok)
    return $n
}

# --- Resolve config: environment variable  >  config.ps1 value  >  built-in default ---
$SRC_ISO     = if ($env:SRC_ISO)     { $env:SRC_ISO }          elseif ($SRC_ISO)     { $SRC_ISO }          else { $null }
$DRIVERS_DIR = if ($env:DRIVERS_DIR) { $env:DRIVERS_DIR }      elseif ($DRIVERS_DIR) { $DRIVERS_DIR }      else { "https://github.com/HuJK-Data/gunyah-guest-drivers-windows" }
$IMAGE_INDEX = if ($env:IMAGE_INDEX) { [int]$env:IMAGE_INDEX } elseif ($IMAGE_INDEX) { [int]$IMAGE_INDEX } else { 0 }       # 0 = list editions and prompt
$DISK_MB     = if ($env:DISK_SIZE_MB){ [int]$env:DISK_SIZE_MB }elseif ($DISK_SIZE_MB){ [int]$DISK_SIZE_MB }else { 40960 }
$OUT_QCOW    = if ($env:OUT_QCOW)    { $env:OUT_QCOW }         elseif ($OUT_QCOW)    { $OUT_QCOW }         else { Join-Path $ROOT "win11-droidvm-final.qcow2" }
$LETTER_ESP  = if ($env:LETTER_ESP)  { $env:LETTER_ESP }       elseif ($LETTER_ESP)  { $LETTER_ESP }       else { Get-FreeDriveLetter }
$LETTER_WIN  = if ($env:LETTER_WIN)  { $env:LETTER_WIN }       elseif ($LETTER_WIN)  { $LETTER_WIN }       else { Get-FreeDriveLetter @($LETTER_ESP) }
Write-Host "[disk] drive letters: ESP=$LETTER_ESP Windows=$LETTER_WIN"

foreach ($t in @("dism", "bcdboot", "diskpart", "qemu-img")) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { throw "$t not found (qemu-img needs QEMU for Windows installed and on PATH)" }
}
if (-not $SRC_ISO -or -not (Test-Path $SRC_ISO)) { throw "Invalid SRC_ISO: set the Win11 ARM64 ISO path in config.ps1" }

$WORK = Join-Path $env:TEMP ("droidvm-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
Show-CommandLine "New-Item" @("-ItemType", "Directory", "-Force", $WORK)
New-Item -ItemType Directory -Force $WORK | Out-Null
$VHDX = Join-Path $WORK "w11.vhdx"
$isoMounted = $false; $vhdAttached = $false

function Cleanup {
    if ($script:vhdAttached) {
        # Release the drive letters first so they don't linger as stale MountedDevices reservations
        # that would make a later run's diskpart 'assign' fail. Best-effort.
        foreach ($L in @($script:LETTER_ESP, $script:LETTER_WIN)) {
            if ($L) {
                Show-CommandLine "cmd" @("/c", "mountvol ${L}: /D")
                & cmd /c "mountvol ${L}: /D" 2>$null | Out-Null
            }
        }
        $s = "select vdisk file=`"$VHDX`"`r`ndetach vdisk`r`nexit"
        $f = Join-Path $WORK "detach.txt"
        $s | Out-File -Encoding ascii $f
        Invoke-DiskPartScript -Path $f -OutNull
    }
    if ($script:isoMounted) {
        Show-CommandLine "Dismount-DiskImage" @("-ImagePath", $SRC_ISO)
        Dismount-DiskImage -ImagePath $SRC_ISO | Out-Null
    }
}

try {
    # === 1) Resolve driver source (URL / local zip / folder) ===
    $drvDir = ""
    if ($DRIVERS_DIR -match '^https?://') {
        $repo = ($DRIVERS_DIR -replace '^https?://github.com/', '') -replace '\.git$', '' -replace '/+$', ''
        Write-Host "[drivers] fetching dev release driver zip from $repo ..."
        $relUri = "https://api.github.com/repos/$repo/releases/tags/dev"
        Show-CommandLine "Invoke-RestMethod" @("-Uri", $relUri, "-Headers", '@{ "User-Agent" = "droidvm" }')
        $rel = Invoke-RestMethod -Uri $relUri -Headers @{ "User-Agent" = "droidvm" }
        $asset = $rel.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
        if (-not $asset) { throw "dev release has no .zip asset (repo=$repo)" }
        $zip = Join-Path $WORK "drivers.zip"
        Show-CommandLine "Invoke-WebRequest" @("-Uri", $asset.browser_download_url, "-OutFile", $zip, "-UseBasicParsing")
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
        $drvExtractDir = Join-Path $WORK "drv"
        Show-CommandLine "Expand-Archive" @($zip, "-DestinationPath", $drvExtractDir, "-Force")
        Expand-Archive $zip -DestinationPath $drvExtractDir -Force
        $drvDir = $drvExtractDir
    }
    elseif ($DRIVERS_DIR -like "*.zip") {
        $drvExtractDir = Join-Path $WORK "drv"
        Show-CommandLine "Expand-Archive" @($DRIVERS_DIR, "-DestinationPath", $drvExtractDir, "-Force")
        Expand-Archive $DRIVERS_DIR -DestinationPath $drvExtractDir -Force
        $drvDir = $drvExtractDir
    }
    else { $drvDir = $DRIVERS_DIR }
    # zip top level is often drivers/, descend to the folder that actually contains *.inf
    if (Test-Path (Join-Path $drvDir "drivers")) { $drvDir = Join-Path $drvDir "drivers" }
    if (-not (Get-ChildItem $drvDir -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        throw "no .inf found in driver folder: $drvDir"
    }
    Write-Host "[drivers] using: $drvDir"

    # === 2) Mount ISO, get install.wim, resolve image index ===
    Show-CommandLine "Mount-DiskImage" @("-ImagePath", $SRC_ISO, "-PassThru")
    $mr = Mount-DiskImage -ImagePath $SRC_ISO -PassThru; $isoMounted = $true
    $isoLetter = ($mr | Get-Volume).DriveLetter
    $wim = "${isoLetter}:\sources\install.wim"
    if (-not (Test-Path $wim)) { throw "$wim not found in ISO" }
    Write-Host "[iso] $SRC_ISO"
    $IMAGE_INDEX = Resolve-ImageIndex $wim $IMAGE_INDEX
    Write-Host "[image] using index $IMAGE_INDEX"

    # === 3) Create + attach VHDX, GPT partition: ESP(FAT32) + MSR + Windows(NTFS) ===
    Write-Host "[disk] creating and partitioning VHDX ..."
    $dp = @"
create vdisk file="$VHDX" maximum=$DISK_MB type=expandable
select vdisk file="$VHDX"
attach vdisk
convert gpt
create partition efi size=260
format fs=fat32 quick label=System
assign letter=$LETTER_ESP
create partition msr size=16
create partition primary
format fs=ntfs quick label=Windows
assign letter=$LETTER_WIN
exit
"@
    $dpFile = Join-Path $WORK "part.txt"
    $dp | Out-File -Encoding ascii $dpFile
    # diskpart exits 0 even when an 'assign letter' fails, so verify the volumes actually mounted.
    $dpOut = Invoke-DiskPartScript -Path $dpFile; $vhdAttached = $true
    $W = "${LETTER_WIN}:"; $S = "${LETTER_ESP}:"
    if (-not (Test-Path "$S\") -or -not (Test-Path "$W\")) {
        throw "diskpart did not mount $S and/or $W (likely a stale drive-letter reservation; set LETTER_ESP/LETTER_WIN to other letters). diskpart output:`n$(( $dpOut | Out-String ).Trim())"
    }

    # === 4) Apply image ===
    Write-Host "[dism] applying install.wim -> $W\ ..."
    Invoke-ExternalCommand -FilePath "dism" -ArgumentList @("/Apply-Image", "/ImageFile:$wim", "/Index:$IMAGE_INDEX", "/ApplyDir:$W\") -OutNull -What "dism /Apply-Image"

    # === 5) Offline driver injection (no signature prompt) ===
    Write-Host "[dism] injecting drivers offline ..."
    Invoke-ExternalCommand -FilePath "dism" -ArgumentList @("/Image:$W\", "/Add-Driver", "/Driver:$drvDir", "/Recurse", "/ForceUnsigned") -OutNull -What "dism /Add-Driver"

    # === 6) Debloat (offline removal of provisioned Appx) ===
    Write-Host "[debloat] removing extra provisioned Appx offline ..."
    $keep = 'VCLibs|NET\.Native|UI\.Xaml|Store|SecHealth|Photos|Notepad|Terminal|WindowsTerminal'
    try {
        Get-AppxProvisionedPackage -Path "$W\" | Where-Object { $_.DisplayName -notmatch $keep } | ForEach-Object {
            try {
                Show-CommandLine "Remove-AppxProvisionedPackage" @("-Path", "$W\", "-PackageName", $_.PackageName)
                Remove-AppxProvisionedPackage -Path "$W\" -PackageName $_.PackageName | Out-Null
            } catch {}
        }
    } catch { Write-Host "  (skipping debloat: $($_.Exception.Message))" -ForegroundColor DarkYellow }

    # === 7) Boot files + BCD (bcdboot uses the ARM64 bootmgr from the image) ===
    Write-Host "[boot] bcdboot + BCD ..."
    Invoke-ExternalCommand -FilePath "bcdboot" -ArgumentList @("$W\Windows", "/s", $S, "/f", "UEFI") -OutNull -What "bcdboot"
    $BCD = "$S\EFI\Microsoft\Boot\BCD"
    Invoke-ExternalCommand -FilePath "bcdedit" -ArgumentList @("/store", $BCD, "/set", "{default}", "testsigning", "on") -OutNull -What "bcdedit testsigning"
    Invoke-ExternalCommand -FilePath "bcdedit" -ArgumentList @("/store", $BCD, "/set", "{default}", "nointegritychecks", "on") -OutNull -What "bcdedit nointegritychecks"

    # === 8) OOBE unattend (create USER / autologon) ===
    Show-CommandLine "New-Item" @("-ItemType", "Directory", "-Force", "$W\Windows\Panther")
    New-Item -ItemType Directory -Force "$W\Windows\Panther" | Out-Null
    $unattendSrc = Join-Path $HERE "unattend.xml"
    Show-CommandLine "Copy-Item" @($unattendSrc, "$W\Windows\Panther\unattend.xml", "-Force")
    Copy-Item $unattendSrc "$W\Windows\Panther\unattend.xml" -Force
    Write-Host "[oobe] unattend.xml placed (first boot creates USER, autologon)"

    # === 9) Detach VHDX -> convert to qcow2 ===
    Cleanup; $vhdAttached = $false; $isoMounted = $false
    Write-Host "[qcow2] converting -> $OUT_QCOW ..."
    Invoke-ExternalCommand -FilePath "qemu-img" -ArgumentList @("convert", "-p", "-O", "qcow2", $VHDX, $OUT_QCOW) -What "qemu-img convert"
    $sz = "{0:N1} GB" -f ((Get-Item $OUT_QCOW).Length / 1GB)
    Write-Host "Done  -> $OUT_QCOW ($sz)" -ForegroundColor Green
}
finally {
    Cleanup
    Show-CommandLine "Remove-Item" @("-Recurse", "-Force", $WORK, "-ErrorAction", "SilentlyContinue")
    Remove-Item -Recurse -Force $WORK -ErrorAction SilentlyContinue
}

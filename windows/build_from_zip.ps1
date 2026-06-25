$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$env:SRC_ISO     = "C:\Users\USER\Documents\DroidVMBuild\SW_DVD9_Win_Pro_11_25H2_Arm64_English_Pro_Ent_EDU_N_MLF_X24-13111.ISO"
$env:DRIVERS_DIR = "C:\Users\USER\Documents\DroidVMBuild\drivers-other"
$env:OUT_QCOW    = "C:\Users\USER\Documents\DroidVMBuild\win11-droidvm-other.qcow2"
# IMAGE_INDEX intentionally unset -> build.ps1 lists editions and prompts you to pick
$env:PATH        = "C:\Program Files\qemu;" + $env:PATH

Write-Host "==== BUILD OTHER (uploaded driver) - interactive image index ====" -ForegroundColor Cyan
& "$PSScriptRoot\build.ps1"

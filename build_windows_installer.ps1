# Windows Installer Build Script for GAM
# No interactive prompts or agreements needed - 100% automated!

$ErrorActionPreference = "Stop"

Write-Host "=== GAM Windows Installer Build Script ===" -ForegroundColor Cyan

$projectRoot = $PSScriptRoot
$releaseDir = Join-Path $projectRoot "build\windows_release"
$distDir = Join-Path $projectRoot "dist"
$issPath = Join-Path $projectRoot "windows\installer.iss"

# Find Inno Setup Compiler
$isccPaths = @(
    "C:\Program Files\Inno Setup 7\ISCC.exe",
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe"
)

$iscc = $null
foreach ($path in $isccPaths) {
    if (Test-Path $path) {
        $iscc = $path
        break
    }
}

if (-not $iscc) {
    $found = Get-Command "iscc" -ErrorAction SilentlyContinue
    if ($found) { $iscc = $found.Source }
}

if (-not $iscc) {
    Write-Error "Inno Setup compiler (ISCC.exe) not found. Please install Inno Setup."
    exit 1
}

Write-Host "Found Inno Setup Compiler: $iscc" -ForegroundColor Green

if (-not (Test-Path "$releaseDir\gam.exe")) {
    Write-Host "Checking for downloaded release zip in Downloads..." -ForegroundColor Yellow
    $zipPath = "$env:USERPROFILE\Downloads\gam-windows-x64.zip"
    if (Test-Path $zipPath) {
        Write-Host "Extracting $zipPath to $releaseDir..." -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
        Expand-Archive -Path $zipPath -DestinationPath $releaseDir -Force
    } else {
        Write-Error "No Windows release build found in $releaseDir or Downloads."
        exit 1
    }
}

Write-Host "Compiling Windows installer..." -ForegroundColor Cyan
& $iscc $issPath

$outputExe = Join-Path $distDir "gam-setup-1.0.0.exe"
if (Test-Path $outputExe) {
    Write-Host "Successfully generated: $outputExe" -ForegroundColor Green
    Copy-Item -Path $outputExe -Destination "$env:USERPROFILE\Downloads\gam-setup-1.0.0.exe" -Force
    Write-Host "Copied to: $env:USERPROFILE\Downloads\gam-setup-1.0.0.exe" -ForegroundColor Green
} else {
    Write-Error "Installer generation failed."
}

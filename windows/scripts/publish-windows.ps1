[CmdletBinding()]
param(
    [string] $Version = "dev",
    [string] $FfmpegLicensePath = "",
    [string] $FfmpegReadmePath = "",
    [string] $CudaLicensePath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    throw "Version may contain only letters, digits, dots, underscores, and hyphens."
}

$WindowsRoot = Split-Path -Parent $PSScriptRoot
$RepositoryRoot = Split-Path -Parent $WindowsRoot
$Project = Join-Path $WindowsRoot "src\TranscribeToText.App\TranscribeToText.App.csproj"
$RuntimeRoot = Join-Path $WindowsRoot "runtime\engines"
$ArtifactRoot = Join-Path $WindowsRoot "artifacts"
$PublishRoot = Join-Path $ArtifactRoot "publish\win-x64"
$ExecutablePath = Join-Path $ArtifactRoot "TranscribeToText.App.exe"
$ArchivePath = Join-Path $ArtifactRoot "TranscribeToText-Windows-x64-$Version.zip"

if (-not (Get-Command "dotnet" -ErrorAction SilentlyContinue)) {
    throw "Install the .NET 10 SDK before publishing the Windows client."
}
$RequiredCpuFiles = @(
    "whisper-cli.exe",
    "meeting-whisper.exe",
    "llama-cli.exe",
    "sherpa-onnx-offline-speaker-diarization.exe",
    "ffmpeg.exe",
    "vcomp140.dll",
    "engines.json"
)
$MissingCpuFiles = $RequiredCpuFiles | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $RuntimeRoot "cpu\$_") -PathType Leaf)
}
if ($MissingCpuFiles) {
    throw "Build the full CPU engine bundle first. Missing files in windows/runtime/engines/cpu: $($MissingCpuFiles -join ', '). See windows/README.md."
}
if ([string]::IsNullOrWhiteSpace($FfmpegLicensePath) -or
    -not (Test-Path -LiteralPath $FfmpegLicensePath -PathType Leaf)) {
    throw "A redistribution-ready bundle must include the license file for the supplied FFmpeg build. Pass -FfmpegLicensePath with that file."
}
if ([string]::IsNullOrWhiteSpace($FfmpegReadmePath)) {
    $FfmpegReadmePath = Join-Path (Split-Path -Parent $FfmpegLicensePath) "README.txt"
}
if (-not (Test-Path -LiteralPath $FfmpegReadmePath -PathType Leaf)) {
    throw "Include the supplied FFmpeg build README with its source and external asset references. Pass -FfmpegReadmePath with that file."
}

$VendorRoot = Join-Path $WindowsRoot ".cache\vendor"
$LicenseSources = @(
    @{ Name = "whisper.cpp"; Path = Join-Path (Join-Path $VendorRoot "whisper.cpp") "LICENSE" },
    @{ Name = "llama.cpp"; Path = Join-Path (Join-Path $VendorRoot "llama.cpp") "LICENSE" },
    @{ Name = "sherpa-onnx"; Path = Join-Path (Join-Path $VendorRoot "sherpa-onnx") "LICENSE" }
)
foreach ($license in $LicenseSources) {
    if (-not (Test-Path -LiteralPath $license.Path -PathType Leaf)) {
        throw "The $($license.Name) license file is missing. Build engines first so the pinned source checkouts are present."
    }
}

$CudaRuntime = Join-Path $RuntimeRoot "cuda"
$HasCudaRuntime = @(
    Get-ChildItem -Path (Join-Path $CudaRuntime "cudart64_*.dll") -File -ErrorAction SilentlyContinue
).Count -gt 0
if ($HasCudaRuntime -and ([string]::IsNullOrWhiteSpace($CudaLicensePath) -or
    -not (Test-Path -LiteralPath $CudaLicensePath -PathType Leaf))) {
    throw "The bundle contains CUDA runtime DLLs. Pass -CudaLicensePath with the applicable CUDA redistribution license/notice."
}

New-Item -ItemType Directory -Path $ArtifactRoot -Force | Out-Null
$artifactRootFull = [IO.Path]::GetFullPath($ArtifactRoot)
$artifactPrefix = $artifactRootFull.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
$publishRootFull = [IO.Path]::GetFullPath($PublishRoot)
if (-not $publishRootFull.StartsWith($artifactPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "The publish output path must stay inside windows/artifacts."
}
if (Test-Path -LiteralPath $PublishRoot) {
    Remove-Item -LiteralPath $PublishRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $PublishRoot -Force | Out-Null

& dotnet publish $Project -c Release -r win-x64 --self-contained true -p:Platform=x64 `
    -p:EnableMsixTooling=true -p:WindowsAppSDKSelfContained=true `
    -p:IncludeAllContentForSelfExtract=true -p:PublishSingleFile=true `
    -p:EnableCompressionInSingleFile=true -p:DebugType=None -p:DebugSymbols=false `
    -o $PublishRoot
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

$PublishedExecutable = Join-Path $PublishRoot "TranscribeToText.App.exe"
if (-not (Test-Path -LiteralPath $PublishedExecutable -PathType Leaf)) {
    throw "The single-file publish did not produce TranscribeToText.App.exe."
}
$publishedExeInfo = Get-Item -LiteralPath $PublishedExecutable
if ($publishedExeInfo.Length -lt 100MB) {
    throw "The published executable is unexpectedly small; verify that the CPU engine bundle was included."
}
Copy-Item -LiteralPath $PublishedExecutable -Destination $ExecutablePath -Force

$LicenseRoot = Join-Path $PublishRoot "licenses"
New-Item -ItemType Directory -Path $LicenseRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $RepositoryRoot "ThirdPartyNotices.md") -Destination $LicenseRoot -Force
Copy-Item -Path (Join-Path $RepositoryRoot "ThirdPartyLicenses\*") -Destination $LicenseRoot -Recurse -Force
foreach ($license in $LicenseSources) {
    Copy-Item -LiteralPath $license.Path -Destination (Join-Path $LicenseRoot "$($license.Name)-LICENSE.txt") -Force
}
Copy-Item -LiteralPath $FfmpegLicensePath -Destination (Join-Path $LicenseRoot "FFmpeg-LICENSE.txt") -Force
Copy-Item -LiteralPath $FfmpegReadmePath -Destination (Join-Path $LicenseRoot "FFmpeg-Build-README.txt") -Force
if ($HasCudaRuntime) {
    Copy-Item -LiteralPath $CudaLicensePath -Destination (Join-Path $LicenseRoot "CUDA-LICENSE.txt") -Force
}
if (Test-Path -LiteralPath $ArchivePath) {
    Remove-Item -LiteralPath $ArchivePath -Force
}
Compress-Archive -Path (Join-Path $PublishRoot "*") -DestinationPath $ArchivePath -CompressionLevel Optimal

Write-Host "Single-file Windows x64 executable: $ExecutablePath"
Write-Host "Windows x64 bundle ZIP with third-party notices: $ArchivePath"
Write-Host "GPU engine folders present in windows/runtime/engines were included when available."

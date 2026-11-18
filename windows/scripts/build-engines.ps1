[CmdletBinding()]
param(
    [ValidateSet("CPU", "CUDA", "Vulkan")]
    [string] $Backend = "CPU",
    [string] $FfmpegPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$WindowsRoot = Split-Path -Parent $PSScriptRoot
$RepositoryRoot = Split-Path -Parent $WindowsRoot
$VendorRoot = Join-Path $WindowsRoot ".cache\vendor"
$BuildRoot = Join-Path $WindowsRoot "build"
$RuntimeRoot = Join-Path $WindowsRoot "runtime\engines\$($Backend.ToLowerInvariant())"

$PinnedRepositories = @(
    @{
        Name = "whisper.cpp"
        Url = "https://github.com/ggml-org/whisper.cpp.git"
        Revision = "6e4ab854f67f743900934a703d5603419384c961"
    },
    @{
        Name = "llama.cpp"
        Url = "https://github.com/ggml-org/llama.cpp.git"
        Revision = "cb7934c52ca8710994b2ecc19775ebefcfdb8d01"
    },
    @{
        Name = "sherpa-onnx"
        Url = "https://github.com/k2-fsa/sherpa-onnx.git"
        Revision = "040afe360a38e25daaa325ce8889abf93ea02609"
    }
)

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath exited with code $LASTEXITCODE."
    }
}

function Get-PinnedCheckout {
    param([Parameter(Mandatory = $true)][hashtable] $Repository)

    $path = Join-Path $VendorRoot $Repository.Name
    if (-not (Test-Path (Join-Path $path ".git"))) {
        if (Test-Path $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
        New-Item -ItemType Directory -Path $VendorRoot -Force | Out-Null
        Invoke-External "git" @("clone", "--filter=blob:none", "--no-checkout", $Repository.Url, $path)
    }

    Invoke-External "git" @("-C", $path, "remote", "set-url", "origin", $Repository.Url)
    Invoke-External "git" @("-C", $path, "fetch", "--depth", "1", "origin", $Repository.Revision)
    Invoke-External "git" @("-C", $path, "checkout", "--detach", $Repository.Revision)
    return $path
}

function Get-Executable {
    param(
        [Parameter(Mandatory = $true)][string] $SearchRoot,
        [Parameter(Mandatory = $true)][string] $Name
    )
    $match = Get-ChildItem -LiteralPath $SearchRoot -Filter $Name -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } |
        Select-Object -First 1
    if ($null -eq $match) {
        throw "Could not find $Name beneath $SearchRoot."
    }
    return $match.FullName
}

function Copy-ExecutableAndAdjacentDlls {
    param(
        [Parameter(Mandatory = $true)][string] $ExecutablePath,
        [Parameter(Mandatory = $true)][string] $DestinationDirectory
    )
    Copy-Item -LiteralPath $ExecutablePath -Destination $DestinationDirectory -Force
    $sourceDirectory = Split-Path -Parent $ExecutablePath
    Get-ChildItem -LiteralPath $sourceDirectory -Filter "*.dll" -File -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $DestinationDirectory -Force }
}

foreach ($tool in @("cmake", "git")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Install $tool and reopen PowerShell before building the native engines."
    }
}

if ($Backend -eq "CUDA" -and -not (Get-Command "nvcc" -ErrorAction SilentlyContinue)) {
    throw "The CUDA backend requires the NVIDIA CUDA Toolkit and nvcc on PATH."
}
if ($Backend -eq "Vulkan" -and [string]::IsNullOrWhiteSpace($env:VULKAN_SDK)) {
    throw "The Vulkan backend requires the Vulkan SDK and its VULKAN_SDK environment variable."
}

$WhisperSource = Get-PinnedCheckout $PinnedRepositories[0]
$LlamaSource = Get-PinnedCheckout $PinnedRepositories[1]
$SherpaSource = Get-PinnedCheckout $PinnedRepositories[2]
New-Item -ItemType Directory -Path $BuildRoot, $RuntimeRoot -Force | Out-Null

$BackendFlags = @("-DGGML_CUDA=OFF", "-DGGML_VULKAN=OFF", "-DGGML_HIP=OFF")
switch ($Backend) {
    "CUDA" { $BackendFlags = @("-DGGML_CUDA=ON", "-DGGML_VULKAN=OFF", "-DGGML_HIP=OFF") }
    "Vulkan" { $BackendFlags = @("-DGGML_CUDA=OFF", "-DGGML_VULKAN=ON", "-DGGML_HIP=OFF") }
}
$CommonCMakeFlags = @(
    "-A", "x64",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
    "-DBUILD_SHARED_LIBS=OFF",
    "-DGGML_METAL=OFF",
    "-DGGML_METAL_EMBED_LIBRARY=OFF",
    "-DGGML_BACKEND_DL=OFF"
) + $BackendFlags

$WhisperBuild = Join-Path $BuildRoot "whisper-$($Backend.ToLowerInvariant())"
$WhisperFlags = $CommonCMakeFlags + @(
    "-DWHISPER_BUILD_TESTS=OFF",
    "-DWHISPER_BUILD_EXAMPLES=ON"
)
Invoke-External "cmake" (@("-S", $WhisperSource, "-B", $WhisperBuild) + $WhisperFlags)
Invoke-External "cmake" @("--build", $WhisperBuild, "--config", "Release", "--target", "whisper-cli")

$MeetingBuild = Join-Path $BuildRoot "meeting-whisper-$($Backend.ToLowerInvariant())"
$MeetingFlags = $CommonCMakeFlags + @(
    "-DWHISPER_CPP_PATH=$WhisperSource",
    "-DWHISPER_BUILD_TESTS=OFF",
    "-DWHISPER_BUILD_EXAMPLES=ON"
)
Invoke-External "cmake" (@("-S", (Join-Path $RepositoryRoot "MeetingWhisper"), "-B", $MeetingBuild) + $MeetingFlags)
Invoke-External "cmake" @("--build", $MeetingBuild, "--config", "Release", "--target", "meeting-whisper")

$LlamaBuild = Join-Path $BuildRoot "llama-$($Backend.ToLowerInvariant())"
$LlamaFlags = $CommonCMakeFlags + @(
    "-DLLAMA_BUILD_TESTS=OFF",
    "-DLLAMA_BUILD_EXAMPLES=ON",
    # llama-cli is currently added under this option in the pinned llama.cpp revision.
    "-DLLAMA_BUILD_SERVER=ON",
    "-DLLAMA_BUILD_APP=OFF",
    "-DLLAMA_BUILD_UI=OFF",
    "-DLLAMA_USE_PREBUILT_UI=OFF",
    "-DCMAKE_CXX_FLAGS=/DNOMINMAX",
    "-DLLAMA_OPENSSL=OFF"
)
Invoke-External "cmake" (@("-S", $LlamaSource, "-B", $LlamaBuild) + $LlamaFlags)
Invoke-External "cmake" @("--build", $LlamaBuild, "--config", "Release", "--target", "llama-cli")

$SherpaBuild = Join-Path $BuildRoot "sherpa-cpu"
$SherpaFlags = @(
    "-A", "x64",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
    "-DBUILD_SHARED_LIBS=OFF",
    "-DSHERPA_ONNX_USE_PRE_INSTALLED_ONNXRUNTIME_IF_AVAILABLE=OFF",
    "-DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=ON",
    "-DSHERPA_ONNX_ENABLE_PYTHON=OFF",
    "-DSHERPA_ONNX_ENABLE_TESTS=OFF",
    "-DSHERPA_ONNX_ENABLE_CHECK=OFF",
    "-DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF",
    "-DSHERPA_ONNX_ENABLE_C_API=OFF",
    "-DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF",
    "-DSHERPA_ONNX_ENABLE_BINARY=ON",
    "-DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF",
    "-DSHERPA_ONNX_ENABLE_TTS=OFF"
)
Invoke-External "cmake" (@("-S", $SherpaSource, "-B", $SherpaBuild) + $SherpaFlags)
Invoke-External "cmake" @("--build", $SherpaBuild, "--config", "Release", "--target", "sherpa-onnx-offline-speaker-diarization")

foreach ($engine in @(
    @{ Root = $WhisperBuild; Name = "whisper-cli.exe" },
    @{ Root = $MeetingBuild; Name = "meeting-whisper.exe" },
    @{ Root = $LlamaBuild; Name = "llama-cli.exe" },
    @{ Root = $SherpaBuild; Name = "sherpa-onnx-offline-speaker-diarization.exe" }
)) {
    $executablePath = Get-Executable -SearchRoot $engine.Root -Name $engine.Name
    Copy-ExecutableAndAdjacentDlls -ExecutablePath $executablePath -DestinationDirectory $RuntimeRoot
}

# whisper.cpp and llama.cpp use MSVC OpenMP. Bundle its app-local runtime so
# CPU engines do not depend on the Visual C++ runtime being preinstalled.
$vswherePath = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswherePath -PathType Leaf)) {
    throw "Visual Studio's vswhere.exe was not found. Install Visual Studio with the Desktop development with C++ workload."
}
$vsInstallPaths = @(& $vswherePath -latest -products "*" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
if ($LASTEXITCODE -ne 0 -or $vsInstallPaths.Count -eq 0) {
    throw "Could not locate the Visual Studio C++ toolset needed to bundle vcomp140.dll."
}
$vcRedistRoot = Join-Path $vsInstallPaths[0] "VC\Redist\MSVC"
$vcompRuntime = Get-ChildItem -LiteralPath $vcRedistRoot -Filter "vcomp140.dll" -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\Microsoft\.VC143\.OpenMP\\vcomp140\.dll$' } |
    Sort-Object { [version]$_.Directory.Parent.Parent.Name } -Descending |
    Select-Object -First 1
if ($null -eq $vcompRuntime) {
    throw "Could not find the x64 MSVC OpenMP redistributable vcomp140.dll under $vcRedistRoot."
}
Copy-Item -LiteralPath $vcompRuntime.FullName -Destination $RuntimeRoot -Force

if ([string]::IsNullOrWhiteSpace($FfmpegPath)) {
    $ffmpegCommand = Get-Command "ffmpeg.exe" -ErrorAction SilentlyContinue
    if ($null -ne $ffmpegCommand) { $FfmpegPath = $ffmpegCommand.Source }
}
if ([string]::IsNullOrWhiteSpace($FfmpegPath)) {
    throw "FFmpeg is required. Install a Windows FFmpeg build and pass -FfmpegPath C:\path\to\ffmpeg.exe."
}
if (-not (Test-Path -LiteralPath $FfmpegPath -PathType Leaf)) { throw "FFmpeg was not found at $FfmpegPath." }
Copy-Item -LiteralPath $FfmpegPath -Destination (Join-Path $RuntimeRoot "ffmpeg.exe") -Force
Get-ChildItem -LiteralPath (Split-Path -Parent $FfmpegPath) -Filter "*.dll" -File -ErrorAction SilentlyContinue |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $RuntimeRoot -Force }

if ($Backend -eq "CUDA") {
    $nvcc = Get-Command "nvcc.exe" -ErrorAction Stop
    $cudaBin = Split-Path -Parent $nvcc.Source
    $cudaPatterns = @("cudart64_*.dll", "cublas64_*.dll", "cublasLt64_*.dll", "nvrtc64_*.dll", "nvJitLink_*.dll")
    foreach ($pattern in $cudaPatterns) {
        Get-ChildItem -LiteralPath $cudaBin -Filter $pattern -File -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $RuntimeRoot -Force }
    }
    foreach ($required in @("cudart64_*.dll", "cublas64_*.dll", "cublasLt64_*.dll")) {
        if (-not (Get-ChildItem -LiteralPath $RuntimeRoot -Filter $required -File -ErrorAction SilentlyContinue)) {
            throw "The CUDA runtime dependency $required was not found in $cudaBin."
        }
    }
}

$manifest = [ordered]@{
    backend = $Backend.ToLowerInvariant()
    architecture = "x64"
    whisperCppRevision = $PinnedRepositories[0].Revision
    llamaCppRevision = $PinnedRepositories[1].Revision
    sherpaOnnxRevision = $PinnedRepositories[2].Revision
    ffmpegBundled = $true
    vcOpenMpRuntimeBundled = $true
    generatedAtUtc = [DateTime]::UtcNow.ToString("O")
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RuntimeRoot "engines.json") -Encoding utf8

Write-Host "Built $Backend engines into $RuntimeRoot"

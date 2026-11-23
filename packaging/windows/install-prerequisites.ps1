# Aura Voice Studio Windows prerequisite bootstrapper.
# Runs elevated from the Inno Setup installer after application files are copied.
$ErrorActionPreference = 'Stop'

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'Aura Voice Studio requires 64-bit Windows.'
}

$appRoot = Split-Path -Parent $PSScriptRoot
$requiredFiles = @(
    'aura_voice_ai.exe',
    'aura_audio_engine.dll',
    'backend_runtime\aura-ai-server.exe'
)

foreach ($relativePath in $requiredFiles) {
    $requiredPath = Join-Path $appRoot $relativePath
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Aura Voice Studio installation is incomplete. Missing: $relativePath"
    }
}

$runtimeRegistryPath = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'

function Test-VcRuntimeInstalled {
    $runtime = Get-ItemProperty -LiteralPath $runtimeRegistryPath -ErrorAction SilentlyContinue
    return ($null -ne $runtime -and [int]$runtime.Installed -eq 1)
}

if (Test-VcRuntimeInstalled) {
    Write-Output 'Microsoft Visual C++ x64 runtime is already installed.'
    exit 0
}

$redistPath = Join-Path $PSScriptRoot 'vc_redist.x64.exe'
if (-not (Test-Path -LiteralPath $redistPath -PathType Leaf)) {
    throw 'The bundled Microsoft Visual C++ runtime installer is missing.'
}

Write-Output 'Installing the bundled Microsoft Visual C++ x64 runtime...'
$process = Start-Process -FilePath $redistPath -ArgumentList @('/install', '/quiet', '/norestart') -Wait -PassThru
$acceptedExitCodes = @(0, 3010, 1638)
if ($process.ExitCode -notin $acceptedExitCodes) {
    throw "Microsoft Visual C++ runtime installation failed with exit code $($process.ExitCode)."
}

if (-not (Test-VcRuntimeInstalled)) {
    throw 'Microsoft Visual C++ runtime installation could not be verified. Restart Windows and run setup again.'
}

if ($process.ExitCode -eq 3010) {
    Write-Output 'The Visual C++ runtime requested a Windows restart. Aura Voice Studio is installed; restart Windows before use if audio components do not load.'
}

Write-Output 'All required Aura Voice Studio Windows components are ready.'

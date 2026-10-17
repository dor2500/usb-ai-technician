<#
.SYNOPSIS
    One-time preparation of the USB stick. Downloads llama.cpp (llama-server) into bin\
    and the gpt-oss-20b model (GGUF, ~12 GB) into models\, and verifies both with SHA-256.

.PARAMETER Backend
    vulkan (default; uses any modern GPU and falls back to the CPU) or cpu.

.EXAMPLE
    .\Setup-USB.cmd
    .\Setup-USB.cmd -Backend cpu
#>
[CmdletBinding()]
param(
    [ValidateSet('vulkan', 'cpu')][string]$Backend = 'vulkan',
    [switch]$SkipLlama,
    [switch]$SkipModel,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# gpt-oss-20b converted to GGUF by the llama.cpp team (original weights: huggingface.co/openai/gpt-oss-20b)
$ModelRepo = 'ggml-org/gpt-oss-20b-GGUF'
$ModelFile = 'gpt-oss-20b-MXFP4.gguf'
$ModelSize = 12109566624
$ModelSha256 = '27cd6c432c7672cb812a92f611cf3ba7bbc35928262bb1e1253ff4ee6ae35901'

$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'bin'
$models = Join-Path $root 'models'

function Write-Step { param([string]$Text) Write-Host "`n> $Text" -ForegroundColor Cyan }

function Test-Sha256 {
    param([string]$Path, [string]$Expected)
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return ($actual -ieq $Expected)
}

function Invoke-Download {
    param([string]$Url, [string]$OutFile, [switch]$Resume)
    $curlArgs = @('-L', '--fail', '--retry', '5', '--retry-delay', '5', '-o', $OutFile)
    if ($Resume) { $curlArgs += @('-C', '-') }
    & curl.exe @curlArgs $Url
    if ($LASTEXITCODE -ne 0) { throw "Download failed (curl exit code $LASTEXITCODE): $Url" }
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    throw 'curl.exe was not found. It ships with Windows 10 (1803) and newer.'
}

Write-Step "Checking the drive at $root"
$drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($root))
Write-Host ('  File system: {0}   Free: {1:N1} GB' -f $drive.DriveFormat, ($drive.AvailableFreeSpace / 1GB))
if (-not $SkipModel) {
    if ($drive.DriveFormat -eq 'FAT32') {
        throw 'This drive is FAT32, which cannot hold files larger than 4 GB. Reformat the USB as exFAT (or NTFS), copy the project back and run setup again.'
    }
    $existing = 0
    foreach ($candidate in (Join-Path $models $ModelFile), (Join-Path $models "$ModelFile.part")) {
        if (Test-Path -LiteralPath $candidate) { $existing = (Get-Item -LiteralPath $candidate).Length }
    }
    $needed = $ModelSize - $existing + 200MB
    if ($drive.AvailableFreeSpace -lt $needed) {
        throw ('Not enough free space: need about {0:N1} GB more.' -f (($needed - $drive.AvailableFreeSpace) / 1GB))
    }
}

if (-not $SkipLlama) {
    $serverExe = Join-Path $bin 'llama-server.exe'
    if ((Test-Path -LiteralPath $serverExe) -and -not $Force) {
        Write-Step 'llama.cpp already present in bin\ (use -Force to update it)'
    }
    else {
        Write-Step "Finding the newest llama.cpp Windows build ($Backend)"
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
        $pattern = "^llama-b\d+-bin-win-$Backend-$arch\.zip$"
        $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=20' -Headers @{ 'User-Agent' = 'usb-ai-technician' }
        $asset = $null
        $release = $null
        foreach ($r in $releases) {
            $asset = $r.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
            if ($asset) { $release = $r; break }
        }
        if (-not $asset) { throw "No llama.cpp release with an asset matching $pattern was found." }
        Write-Host "  $($release.tag_name): $($asset.name) ($([Math]::Round($asset.size / 1MB, 1)) MB)"

        $zip = Join-Path $root 'temp\llama.zip'
        New-Item -ItemType Directory -Path (Split-Path $zip) -Force | Out-Null
        Invoke-Download -Url $asset.browser_download_url -OutFile $zip
        if ($asset.PSObject.Properties['digest'] -and $asset.digest -match '^sha256:([0-9a-f]{64})$') {
            if (-not (Test-Sha256 -Path $zip -Expected $Matches[1])) { Remove-Item $zip -Force; throw 'llama.cpp download is corrupted (SHA-256 mismatch).' }
            Write-Host '  SHA-256 verified.' -ForegroundColor Green
        }

        Get-ChildItem -LiteralPath $bin -Force | Where-Object { $_.Name -ne 'README.md' } | Remove-Item -Recurse -Force
        Expand-Archive -LiteralPath $zip -DestinationPath $bin -Force
        # Some builds unpack into a sub folder - flatten so bin\llama-server.exe exists.
        $found = Get-ChildItem -LiteralPath $bin -Recurse -Filter 'llama-server.exe' | Select-Object -First 1
        if (-not $found) { throw 'llama-server.exe was not in the downloaded archive.' }
        if ($found.DirectoryName -ne $bin) {
            Get-ChildItem -LiteralPath $found.DirectoryName -Force | Move-Item -Destination $bin -Force
        }
        Set-Content -LiteralPath (Join-Path $bin 'VERSION.txt') -Value "$($release.tag_name) $($asset.name)"
        Remove-Item $zip -Force
        Write-Host '  llama.cpp installed into bin\' -ForegroundColor Green
    }
}

if (-not $SkipModel) {
    $target = Join-Path $models $ModelFile
    $partial = "$target.part"
    if ((Test-Path -LiteralPath $target) -and -not $Force) {
        Write-Step "Model already present: models\$ModelFile"
    }
    else {
        Write-Step "Downloading $ModelFile (about 12 GB - it can resume if interrupted)"
        New-Item -ItemType Directory -Path $models -Force | Out-Null
        $have = if (Test-Path -LiteralPath $partial) { (Get-Item -LiteralPath $partial).Length } else { 0 }
        if ($have -lt $ModelSize) {
            Invoke-Download -Url "https://huggingface.co/$ModelRepo/resolve/main/$ModelFile" -OutFile $partial -Resume
        }
        if ((Get-Item -LiteralPath $partial).Length -ne $ModelSize) { throw 'The model file has the wrong size - run setup again to resume.' }
        Write-Host '  Verifying SHA-256 (a few minutes on a USB stick)...'
        if (-not (Test-Sha256 -Path $partial -Expected $ModelSha256)) {
            Remove-Item -LiteralPath $partial -Force
            throw 'The model file is corrupted (SHA-256 mismatch) and was deleted. Run setup again.'
        }
        Move-Item -LiteralPath $partial -Destination $target -Force
        Write-Host '  Model verified and ready.' -ForegroundColor Green
    }
}

Write-Step 'The USB is ready'
Write-Host '  1. Copy the setup files you want to offer into the Installers folder.'
Write-Host '  2. Plug the USB into any Windows 10/11 PC and double-click Start.cmd.'

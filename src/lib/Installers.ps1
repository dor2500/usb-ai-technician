# 2) Install programs that you keep in the Installers\ folder of the USB.
#    Installer type is detected so most setups run silently; unknown ones open normally.

function Get-InstallerTypeFromBytes {
    param([byte[]]$Bytes)
    # Latin-1 maps every byte to one char, so ASCII markers inside the binary are searchable.
    $text = [Text.Encoding]::GetEncoding(28591).GetString($Bytes)
    if ($text.Contains('Inno Setup')) { return 'inno' }
    if ($text.Contains('Nullsoft')) { return 'nsis' }
    if ($text.Contains('.wixburn')) { return 'wix' }
    return 'unknown'
}

function Get-InstallerType {
    param([Parameter(Mandatory)][string]$Path)
    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -eq '.msi') { return 'msi' }
    if ($extension -in '.msix', '.msixbundle', '.appx', '.appxbundle') { return 'msix' }
    if ($extension -ne '.exe') { return 'unknown' }

    $stream = [IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] ([Math]::Min($stream.Length, 8MB))
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -lt $buffer.Length) { $buffer = $buffer[0..([Math]::Max($read, 1) - 1)] }
    }
    finally {
        $stream.Dispose()
    }
    return (Get-InstallerTypeFromBytes -Bytes $buffer)
}

function Get-SilentArguments {
    param([string]$Type)
    switch ($Type) {
        'inno' { return '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' }
        'nsis' { return '/S' }
        'wix' { return '/quiet /norestart' }
        default { return '' }
    }
}

# Optional Installers\installers.json lets you set exact switches per file:
# { "installers": [ { "file": "ChromeSetup*.exe", "args": "/silent /install" },
#                   { "file": "OldTool.exe", "interactive": true } ] }
function Get-InstallerOverrides {
    param([Parameter(Mandatory)][string]$Folder)
    $file = Join-Path $Folder 'installers.json'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    try {
        $config = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($config.installers | Where-Object { $_ })
    }
    catch {
        Write-Caution "Ignoring $file - it is not valid JSON: $($_.Exception.Message)"
        return @()
    }
}

function Get-InstallCommand {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Type,
        $Override = $null
    )
    $customArgs = $null
    $forceInteractive = $false
    if ($Override) {
        if ($Override.PSObject.Properties['interactive'] -and $Override.interactive) { $forceInteractive = $true }
        if ($Override.PSObject.Properties['args'] -and $Override.args) { $customArgs = [string]$Override.args }
    }

    if ($Type -eq 'msix') {
        return [pscustomobject]@{ FilePath = $Path; Arguments = ''; Silent = $true; Appx = $true }
    }
    if ($Type -eq 'msi') {
        $arguments = if ($forceInteractive) { '/i "{0}"' -f $Path } else { '/i "{0}" /qn /norestart' -f $Path }
        if ($customArgs) { $arguments += " $customArgs" }
        return [pscustomobject]@{ FilePath = 'msiexec.exe'; Arguments = $arguments; Silent = -not $forceInteractive; Appx = $false }
    }
    if ($forceInteractive) {
        return [pscustomobject]@{ FilePath = $Path; Arguments = ''; Silent = $false; Appx = $false }
    }
    if ($customArgs) {
        return [pscustomobject]@{ FilePath = $Path; Arguments = $customArgs; Silent = $true; Appx = $false }
    }
    $silent = Get-SilentArguments -Type $Type
    return [pscustomobject]@{ FilePath = $Path; Arguments = $silent; Silent = [bool]$silent; Appx = $false }
}

function Get-UsbInstallers {
    $folder = Join-Path $script:Paths.Root (Get-Setting 'installers.folder' 'Installers')
    if (-not (Test-Path -LiteralPath $folder)) { return , @() }
    $overrides = Get-InstallerOverrides -Folder $folder
    $extensions = '.exe', '.msi', '.msix', '.msixbundle', '.appx', '.appxbundle'
    $files = @(Get-ChildItem -LiteralPath $folder -Recurse -Depth 1 -File -ErrorAction SilentlyContinue |
        Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } | Sort-Object Name)

    $list = for ($i = 0; $i -lt $files.Count; $i++) {
        $file = $files[$i]
        $override = $overrides | Where-Object { $file.Name -like $_.file } | Select-Object -First 1
        $type = Get-InstallerType -Path $file.FullName
        [pscustomobject]@{
            Number = $i + 1
            Name = $file.Name
            Path = $file.FullName
            SizeBytes = $file.Length
            Type = $type
            Command = Get-InstallCommand -Path $file.FullName -Type $type -Override $override
        }
    }
    return , @($list)
}

function Install-UsbItem {
    param([Parameter(Mandatory)]$Item)
    $command = $Item.Command
    if ($command.Appx) {
        $ok = Invoke-Change -Description "install app package $($Item.Name)" -Action {
            Add-AppxPackage -Path $Item.Path -ErrorAction Stop
        }
        return [pscustomobject]@{ Name = $Item.Name; Success = $ok; Detail = $(if ($ok) { 'installed' } else { 'failed' }) }
    }
    if (-not $command.Silent) {
        Write-Caution "  $($Item.Name) will open its own setup window - please click through it."
    }
    $timeout = if ($command.Silent) { [int](Get-Setting 'installers.silentTimeoutMinutes' 30) } else { 0 }
    $code = Invoke-Process -FilePath $command.FilePath -Arguments $command.Arguments -TimeoutMinutes $timeout
    $detail = switch ($code) {
        0 { 'installed' }
        3010 { 'installed, restart needed' }
        1641 { 'installed, restart needed' }
        1602 { 'cancelled by user' }
        1618 { 'another installation is already running - try again' }
        -1 { 'timed out' }
        default { "exit code $code" }
    }
    return [pscustomobject]@{ Name = $Item.Name; Success = ($code -in 0, 1641, 3010); Detail = $detail }
}

function Start-InstallFromUsb {
    Write-Heading '2. Install programs from the USB'
    $folder = Join-Path $script:Paths.Root (Get-Setting 'installers.folder' 'Installers')
    $items = Get-UsbInstallers
    if (-not $items.Count) {
        Write-Info "No installers found. Put .exe / .msi / .msix files in: $folder"
        return
    }
    Write-Host ''
    Write-Host ('  {0} {1} {2} {3}' -f 'No.'.PadRight(4), (Limit-Text 'File' 44), 'Size'.PadRight(10), 'Mode') -ForegroundColor DarkGray
    foreach ($item in $items) {
        $mode = if (-not $item.Command.Silent) { 'opens setup window' }
                elseif ($item.Type -eq 'unknown') { 'silent (custom switches)' }
                else { "silent ($($item.Type))" }
        Write-Host ('  {0} {1} {2} {3}' -f ([string]$item.Number).PadRight(4), (Limit-Text $item.Name 44), (Format-Size $item.SizeBytes).PadRight(10), $mode)
    }
    Write-Host ''
    $answer = (Read-Host '  Which to install? (e.g. 1,3-4 / all / empty = none)').Trim()
    if (-not $answer) { Write-Info 'Nothing installed.'; return }
    try {
        $numbers = if ($answer -eq 'all') { 1..$items.Count } else { ConvertTo-IndexList -Text $answer -Max $items.Count }
    }
    catch {
        Write-Caution "  $($_.Exception.Message)"
        return
    }

    $results = foreach ($n in $numbers) {
        $item = $items[$n - 1]
        Write-Info "Installing $($item.Name)..."
        $result = Install-UsbItem -Item $item
        if ($result.Success) { Write-Good "  $($result.Detail)" } else { Write-Problem "  $($result.Detail)" }
        $result
    }
    $ok = @($results | Where-Object Success).Count
    Write-Good ("Installed {0} of {1}." -f $ok, @($numbers).Count)
}

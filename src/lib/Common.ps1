# Shared helpers: session paths, logging, console UI, input parsing, process runner.
# Written for Windows PowerShell 5.1 (the version built into every Windows 10/11).

function Initialize-Session {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$DryRun
    )
    $script:Paths = @{
        Root = $Root
        Bin  = Join-Path $Root 'bin'
        Models = Join-Path $Root 'models'
        Config = Join-Path $Root 'config'
        Logs = Join-Path $Root 'logs'
        Temp = Join-Path $Root 'temp'
    }
    $script:DryRun = [bool]$DryRun
    $script:Settings = $null
    $script:LogFile = $null

    # Everything this tool writes (logs, scratch files) stays on the USB drive.
    foreach ($dir in $script:Paths.Logs, $script:Paths.Temp) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    $script:OriginalTemp = $env:TEMP
    $env:TEMP = $script:Paths.Temp
    $env:TMP = $script:Paths.Temp

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $script:Paths.Logs ('{0}-{1}.log' -f $stamp, $env:COMPUTERNAME)
    Write-AppLog ('Session started. DryRun={0}' -f $script:DryRun)
}

function Close-Session {
    if ($script:OriginalTemp) {
        $env:TEMP = $script:OriginalTemp
        $env:TMP = $script:OriginalTemp
    }
    if ($script:Paths -and (Test-Path -LiteralPath $script:Paths.Temp)) {
        Get-ChildItem -LiteralPath $script:Paths.Temp -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Import-Settings {
    $file = Join-Path $script:Paths.Config 'settings.json'
    if (Test-Path -LiteralPath $file) {
        $script:Settings = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    }
}

function Get-Setting {
    param(
        [Parameter(Mandatory)][string]$Path,
        $Default = $null
    )
    $node = $script:Settings
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $node -or -not ($node.PSObject.Properties.Name -contains $part)) { return $Default }
        $node = $node.$part
    }
    if ($null -eq $node) { return $Default }
    return $node
}

# ---------------------------------------------------------------- logging / output

function Write-AppLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    if (-not $script:LogFile) { return }
    try {
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # The drive may have been unplugged; never let logging break the run.
    }
}

function Write-Info { param([string]$Message) Write-Host $Message; Write-AppLog $Message }
function Write-Good { param([string]$Message) Write-Host $Message -ForegroundColor Green; Write-AppLog $Message }
function Write-Caution { param([string]$Message) Write-Host $Message -ForegroundColor Yellow; Write-AppLog $Message -Level WARN }
function Write-Problem { param([string]$Message) Write-Host $Message -ForegroundColor Red; Write-AppLog $Message -Level ERROR }

function Write-Heading {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host ('=== {0} ===' -f $Text) -ForegroundColor Cyan
    Write-AppLog "== $Text"
}

# ---------------------------------------------------------------- formatting

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -le 0) { return '-' }
    $units = 'B', 'KB', 'MB', 'GB', 'TB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes /= 1024; $i++ }
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:N1} {1}', $Bytes, $units[$i])
}

function Limit-Text {
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -le $Width) { return $Text.PadRight($Width) }
    return $Text.Substring(0, $Width - 1) + '~'
}

# ---------------------------------------------------------------- input

# "1,3-5" -> 1,3,4,5. Throws on anything that is not a number/range inside 1..Max.
function ConvertTo-IndexList {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$Max
    )
    $numbers = New-Object System.Collections.Generic.List[int]
    foreach ($part in ($Text -split '[,\s]+')) {
        if (-not $part) { continue }
        if ($part -match '^(\d{1,6})-(\d{1,6})$') {
            $from = [int]$Matches[1]
            $to = [int]$Matches[2]
            if ($from -gt $to) { $from, $to = $to, $from }
        }
        elseif ($part -match '^\d{1,6}$') {
            $from = [int]$part
            $to = $from
        }
        else {
            throw "Not a number or range: '$part'"
        }
        if ($from -lt 1 -or $to -gt $Max) { throw "Numbers must be between 1 and $Max (got '$part')" }
        foreach ($n in $from..$to) { $numbers.Add($n) }
    }
    return , @($numbers | Sort-Object -Unique)
}

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Prompt, [bool]$Default = $false)
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "$Prompt $suffix").Trim().ToLowerInvariant()
        if ($answer -eq '') { return $Default }
        if ($answer -in 'y', 'yes') { return $true }
        if ($answer -in 'n', 'no') { return $false }
    }
}

# Used before anything destructive: the user has to type the exact word.
function Read-Confirmation {
    param([Parameter(Mandatory)][string]$Prompt, [string]$Word = 'YES')
    $answer = Read-Host ("{0} Type {1} to continue" -f $Prompt, $Word)
    return ($answer.Trim() -ceq $Word)
}

# ---------------------------------------------------------------- system

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DriveFormat {
    param([Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Path).Path)
    return (New-Object IO.DriveInfo($root)).DriveFormat
}

# Runs a program with the PC's own temp folder (so installers never unpack onto the USB),
# waits for it, and returns the exit code. -1 means it timed out and was stopped.
function Invoke-Process {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [int]$TimeoutMinutes = 0,
        [switch]$Hidden
    )
    if ($script:DryRun) {
        Write-Info "  [dry-run] would run: $FilePath $Arguments"
        return 0
    }
    Write-AppLog "RUN: $FilePath $Arguments"
    $savedTemp = $env:TEMP
    $savedTmp = $env:TMP
    if ($script:OriginalTemp) {
        $env:TEMP = $script:OriginalTemp
        $env:TMP = $script:OriginalTemp
    }
    try {
        $startArgs = @{ FilePath = $FilePath; PassThru = $true }
        if ($Arguments) { $startArgs.ArgumentList = $Arguments }
        if ($Hidden) { $startArgs.WindowStyle = 'Hidden' }
        $process = Start-Process @startArgs
        $null = $process.Handle   # keeps ExitCode readable on Windows PowerShell 5.1
        if ($TimeoutMinutes -gt 0) {
            if (-not $process.WaitForExit($TimeoutMinutes * 60000)) {
                & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
                Write-Problem "  Timed out after $TimeoutMinutes minutes - stopped."
                return -1
            }
        }
        else {
            $process.WaitForExit()
        }
        return $process.ExitCode
    }
    finally {
        $env:TEMP = $savedTemp
        $env:TMP = $savedTmp
    }
}

# Wraps a small state change (registry write, file delete) so -DryRun can skip it.
function Invoke-Change {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    if ($script:DryRun) {
        Write-Info "  [dry-run] would: $Description"
        return $true
    }
    Write-AppLog "DO: $Description"
    try {
        $null = & $Action
        return $true
    }
    catch {
        Write-Problem ("  Failed: {0} - {1}" -f $Description, $_.Exception.Message)
        return $false
    }
}

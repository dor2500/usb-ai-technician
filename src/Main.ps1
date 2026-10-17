<#
.SYNOPSIS
    USB AI Technician - clean, install and update a Windows PC straight from a USB stick,
    guided by a local AI model (gpt-oss-20b) that never leaves the drive.

.PARAMETER Action
    Menu (default), Cleanup, Install, Update, All, UndoUpdateLock or Chat.

.PARAMETER DryRun
    Show what would happen without changing anything on the PC.

.PARAMETER NoAI
    Do not load the AI model (useful on PCs with less than 16 GB of RAM).

.EXAMPLE
    .\Start.cmd
    .\Start.cmd -Action All
    .\Start.cmd -DryRun -NoAI
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Cleanup', 'Install', 'Update', 'All', 'UndoUpdateLock', 'Chat')]
    [string]$Action = 'Menu',
    [switch]$DryRun,
    [switch]$NoAI
)

$root = Split-Path -Parent $PSScriptRoot
foreach ($lib in 'Common', 'Llm', 'Cleanup', 'Installers', 'WindowsUpdate') {
    . (Join-Path $PSScriptRoot "lib\$lib.ps1")
}

function Show-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  +------------------------------------------------------------------+' -ForegroundColor Cyan
    Write-Host '  |   USB AI TECHNICIAN                                              |' -ForegroundColor Cyan
    Write-Host '  |   Clean up - Install - Update   |   local AI: gpt-oss-20b        |' -ForegroundColor Cyan
    Write-Host '  +------------------------------------------------------------------+' -ForegroundColor Cyan
    if ($script:DryRun) { Write-Host '   DRY RUN - nothing on this PC will be changed' -ForegroundColor Yellow }
    Write-Host ''
}

function Show-SystemSummary {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction SilentlyContinue
    $ramGb = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $caption = ([string]$os.Caption) -replace '[\u200E\u200F]', ''
    Write-Info ('  PC     {0} - {1} (build {2})' -f $env:COMPUTERNAME, $caption, $os.BuildNumber)
    Write-Info ('  RAM    {0} GB    Free on {1} {2}' -f $ramGb, $env:SystemDrive, (Format-Size $disk.FreeSpace))
    Write-Info ('  USB    {0}' -f $script:Paths.Root)

    $reason = Get-AiUnavailableReason
    if ($reason) {
        Write-Caution "  AI     off - $reason"
    }
    else {
        Write-Good ('  AI     ready to load: {0}' -f (Split-Path -Leaf (Get-LlmModelPath)))
        if ($ramGb -lt 16) {
            Write-Caution '         This PC has less than 16 GB RAM - the AI may be very slow. Consider -NoAI.'
        }
    }
}

function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host '  1  Clean up this PC        (AI suggests junk, you choose what to keep)'
        Write-Host '  2  Install programs        (from the Installers folder on this USB)'
        Write-Host '  3  Update Windows          (then switch to security-only updates)'
        Write-Host '  4  Do all three            (1 -> 2 -> 3)'
        Write-Host '  5  Ask the AI technician'
        Write-Host '  6  Undo the update lock    (restore original Windows Update settings)'
        Write-Host '  0  Exit'
        $choice = (Read-Host '  Choose').Trim()
        switch ($choice) {
            '1' { Start-Cleanup }
            '2' { Start-InstallFromUsb }
            '3' { Start-WindowsUpdate }
            '4' { Start-Cleanup; Start-InstallFromUsb; Start-WindowsUpdate }
            '5' { Start-AiChat }
            '6' { Restore-UpdatePolicy }
            '0' { return }
            default { Write-Caution '  Please type a number from the menu.' }
        }
    }
}

Initialize-Session -Root $root -DryRun:$DryRun
Import-Settings
$script:NoAI = [bool]$NoAI

if (-not (Test-IsAdmin) -and -not $DryRun) {
    Write-Problem 'Administrator rights are required. Start the tool with Start.cmd (it asks for them),'
    Write-Problem 'or use -DryRun to look around without changing anything.'
    Close-Session
    exit 1
}

try {
    Show-Banner
    Show-SystemSummary
    switch ($Action) {
        'Cleanup' { Start-Cleanup }
        'Install' { Start-InstallFromUsb }
        'Update' { Start-WindowsUpdate }
        'All' { Start-Cleanup; Start-InstallFromUsb; Start-WindowsUpdate }
        'UndoUpdateLock' { Restore-UpdatePolicy }
        'Chat' { Start-AiChat }
        default { Show-Menu }
    }
    if ($script:RebootNeeded -and -not $DryRun) {
        if (Read-YesNo -Prompt 'Restart the PC now to finish updates?' -Default $false) {
            & shutdown.exe /r /t 30 /c 'USB AI Technician: restarting to finish Windows updates'
            Write-Info 'Restarting in 30 seconds. You can unplug the USB now.'
        }
    }
}
finally {
    Stop-LlmServer
    Write-AppLog 'Session ended'
    Close-Session
}
Write-Good "Done. A log of this session is on the USB in $($script:Paths.Logs)"

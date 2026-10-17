# 1) Clean the PC: list installed programs and Store apps, let the AI suggest what is junk,
#    ask the user what to KEEP, then uninstall the rest. Optionally clear old temp files.

function Get-ProtectedPatterns {
    $file = Join-Path $script:Paths.Config 'protected.json'
    if (-not (Test-Path -LiteralPath $file)) { return [pscustomobject]@{ programNamePatterns = @(); storeNamePatterns = @() } }
    return (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Test-MatchesAny {
    param([string]$Text, [string[]]$Patterns)
    foreach ($pattern in $Patterns) {
        if ($pattern -and $Text -match $pattern) { return $true }
    }
    return $false
}

function Get-InstalledPrograms {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $seen = @{}
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.DisplayName) { continue }
            # Hidden components, patches and entries that cannot be uninstalled are not "programs".
            if ($p.SystemComponent -eq 1 -or $p.ParentKeyName -or $p.ParentDisplayName) { continue }
            if (-not ($p.UninstallString -or $p.QuietUninstallString)) { continue }
            if ($p.ReleaseType -in 'Update', 'Hotfix', 'Security Update', 'Update Rollup', 'Service Pack') { continue }
            if ($p.DisplayName -match '\(KB\d+\)') { continue }

            $name = ([string]$p.DisplayName).Trim()
            $dedupe = '{0}|{1}' -f $name, $p.DisplayVersion
            if ($seen.ContainsKey($dedupe)) { continue }
            $seen[$dedupe] = $true

            $size = 0
            if ($p.EstimatedSize) { $size = [double]$p.EstimatedSize * 1KB }
            [pscustomobject]@{
                Number = 0
                Kind = 'Program'
                Name = $name
                Publisher = ([string]$p.Publisher).Trim()
                Version = [string]$p.DisplayVersion
                SizeBytes = $size
                UninstallString = [string]$p.UninstallString
                QuietUninstallString = [string]$p.QuietUninstallString
                PackageName = $null
                Verdict = 'ask'
                Reason = ''
                ToRemove = $false
            }
        }
    }
}

function Get-InstalledStoreApps {
    # -AllUsers needs admin; a -DryRun without admin still gets the current user's apps.
    try { $all = @(Get-AppxPackage -AllUsers -ErrorAction Stop) }
    catch { $all = @(Get-AppxPackage -ErrorAction SilentlyContinue) }
    $packages = $all | Where-Object {
        -not $_.IsFramework -and -not $_.IsResourcePackage -and -not $_.NonRemovable -and $_.SignatureKind -ne 'System'
    }
    foreach ($group in ($packages | Group-Object Name)) {
        $pkg = $group.Group[0]
        [pscustomobject]@{
            Number = 0
            Kind = 'Store app'
            Name = $pkg.Name
            Publisher = ($pkg.Publisher -replace '^CN=([^,]+).*$', '$1')
            Version = [string]$pkg.Version
            SizeBytes = 0
            UninstallString = $null
            QuietUninstallString = $null
            PackageName = $pkg.Name
            Verdict = 'ask'
            Reason = ''
            ToRemove = $false
        }
    }
}

# All removable things, minus protected ones, numbered 1..N.
function Get-CleanupCandidates {
    $protected = Get-ProtectedPatterns
    $items = @(Get-InstalledPrograms | Where-Object { -not (Test-MatchesAny -Text $_.Name -Patterns $protected.programNamePatterns) })
    if (Get-Setting 'cleanup.includeStoreApps' $true) {
        $items += @(Get-InstalledStoreApps | Where-Object { -not (Test-MatchesAny -Text $_.Name -Patterns $protected.storeNamePatterns) })
    }
    $items = @($items | Sort-Object Kind, Name)
    for ($i = 0; $i -lt $items.Count; $i++) { $items[$i].Number = $i + 1 }
    return , $items
}

# Works out how to uninstall a registry entry. Silent when Windows/MSI allows it,
# otherwise the program's own uninstaller window opens for the user.
function Get-UninstallCommand {
    param([string]$UninstallString, [string]$QuietUninstallString)
    $guidPattern = '(\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\})'
    if ($QuietUninstallString) {
        return [pscustomobject]@{ FilePath = 'cmd.exe'; Arguments = ('/c "{0}"' -f $QuietUninstallString); Silent = $true }
    }
    if ($UninstallString -match '(?i)msiexec' -and $UninstallString -match $guidPattern) {
        return [pscustomobject]@{ FilePath = 'msiexec.exe'; Arguments = ('/x {0} /qn /norestart' -f $Matches[1]); Silent = $true }
    }
    if ($UninstallString) {
        return [pscustomobject]@{ FilePath = 'cmd.exe'; Arguments = ('/c "{0}"' -f $UninstallString); Silent = $false }
    }
    return $null
}

function Show-CleanupTable {
    param([object[]]$Items)
    Write-Host ''
    Write-Host ('  {0} {1} {2} {3} {4} {5}' -f 'No.'.PadRight(4), 'Action'.PadRight(8), 'AI'.PadRight(7), (Limit-Text 'Name' 40), (Limit-Text 'Publisher' 22), 'AI reason') -ForegroundColor DarkGray
    foreach ($item in $Items) {
        $action = if ($item.ToRemove) { 'REMOVE' } else { 'keep' }
        $color = switch ($item.Verdict) { 'remove' { 'Red' } 'keep' { 'Green' } default { 'Yellow' } }
        $line = '  {0} {1} {2} {3} {4} {5}' -f ([string]$item.Number).PadRight(4), $action.PadRight(8), $item.Verdict.PadRight(7), (Limit-Text $item.Name 40), (Limit-Text $item.Publisher 22), $item.Reason
        if ($item.ToRemove) { Write-Host $line -ForegroundColor $color -BackgroundColor DarkGray }
        else { Write-Host $line -ForegroundColor $color }
    }
}

# Interactive picker. Returns the items to remove, or $null if the user cancelled.
function Read-CleanupSelection {
    param([object[]]$Items)
    while ($true) {
        Show-CleanupTable -Items $Items
        $count = @($Items | Where-Object ToRemove).Count
        Write-Host ''
        Write-Host "  $count marked for removal. Everything else is kept." -ForegroundColor Cyan
        Write-Host '  k 3,5-7  keep these        r 9,12  remove these        ai  reset to AI suggestions'
        Write-Host '  keepall  keep everything   go      continue            q   cancel'
        $command = (Read-Host '  choice').Trim()
        try {
            switch -Regex ($command) {
                '^(go|g)$' { return , @($Items | Where-Object ToRemove) }
                '^(q|quit|cancel)$' { return $null }
                '^keepall$' { foreach ($item in $Items) { $item.ToRemove = $false } }
                '^ai$' { foreach ($item in $Items) { $item.ToRemove = ($item.Verdict -eq 'remove') } }
                '^([kr])\s+(.+)$' {
                    $remove = ($Matches[1] -eq 'r')
                    foreach ($n in (ConvertTo-IndexList -Text $Matches[2] -Max $Items.Count)) { $Items[$n - 1].ToRemove = $remove }
                }
                default { Write-Caution '  Unknown command.' }
            }
        }
        catch {
            Write-Caution "  $($_.Exception.Message)"
        }
    }
}

function New-SafetyRestorePoint {
    param([Parameter(Mandatory)][string]$Label)
    if (-not (Get-Setting 'cleanup.createRestorePoint' $true)) { return $true }
    Write-Info 'Creating a System Restore point first...'
    $ok = Invoke-Change -Description "create restore point '$Label'" -Action {
        Checkpoint-Computer -Description $Label -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
    }
    if ($ok) { Write-Good '  Restore point created.'; return $true }
    Write-Caution '  Could not create a restore point (System Protection may be off on this PC).'
    return (Read-YesNo -Prompt '  Continue without a restore point?' -Default $false)
}

function Remove-CleanupItem {
    param([Parameter(Mandatory)]$Item)
    if ($Item.Kind -eq 'Store app') {
        $ok = Invoke-Change -Description "remove Store app $($Item.PackageName)" -Action {
            Get-AppxPackage -AllUsers -Name $Item.PackageName | Remove-AppxPackage -AllUsers -ErrorAction Stop
        }
        return [pscustomobject]@{ Name = $Item.Name; Success = $ok; Detail = $(if ($ok) { 'removed' } else { 'failed' }) }
    }

    $command = Get-UninstallCommand -UninstallString $Item.UninstallString -QuietUninstallString $Item.QuietUninstallString
    if (-not $command) { return [pscustomobject]@{ Name = $Item.Name; Success = $false; Detail = 'no uninstall command' } }
    if (-not $command.Silent) {
        Write-Caution "  $($Item.Name) has no silent uninstaller - its own window will open, please follow it."
    }
    $timeout = if ($command.Silent) { 30 } else { 0 }
    $code = Invoke-Process -FilePath $command.FilePath -Arguments $command.Arguments -TimeoutMinutes $timeout -Hidden:$command.Silent
    $success = $code -in 0, 1641, 3010
    $detail = switch ($code) { 0 { 'removed' } 1641 { 'removed, restart needed' } 3010 { 'removed, restart needed' } default { "exit code $code" } }
    return [pscustomobject]@{ Name = $Item.Name; Success = $success; Detail = $detail }
}

function Clear-OldTempFiles {
    $folders = @($script:OriginalTemp, (Join-Path $env:windir 'Temp')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        ForEach-Object { (Resolve-Path -LiteralPath $_).Path.TrimEnd('\') } |
        Sort-Object -Unique
    $cutoff = (Get-Date).AddDays(-1)
    $files = @(foreach ($folder in $folders) {
        # Never touch the USB itself, even if TEMP somehow points at it.
        if ($folder.StartsWith($script:Paths.Root, [StringComparison]::OrdinalIgnoreCase)) { continue }
        Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff }
    })
    $total = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $files.Count) { Write-Info '  No old temp files found.'; return }
    Write-Info ('  Found {0} temp files older than a day ({1}) in: {2}' -f $files.Count, (Format-Size $total), ($folders -join ', '))
    if (-not (Read-YesNo -Prompt '  Delete them?' -Default $true)) { return }
    if ($script:DryRun) { Write-Info "  [dry-run] would delete $($files.Count) files"; return }
    $freed = 0
    foreach ($file in $files) {
        try {
            $length = $file.Length
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $freed += $length
        }
        catch {
            # In use by a running program - skip it.
        }
    }
    Write-Good ('  Freed {0}.' -f (Format-Size $freed))
}

function Start-Cleanup {
    Write-Heading '1. Clean up this PC'
    Write-Info 'Scanning installed programs...'
    $items = Get-CleanupCandidates
    if (-not $items.Count) { Write-Info 'Nothing removable was found.'; return }
    Write-Info ("Found {0} programs/apps (drivers, runtimes and system parts are hidden and always kept)." -f $items.Count)

    if (Start-LlmServer) {
        $verdicts = Get-AiProgramVerdicts -Items $items
        foreach ($item in $items) {
            if ($verdicts.ContainsKey($item.Number)) {
                $item.Verdict = $verdicts[$item.Number].Verdict
                $item.Reason = $verdicts[$item.Number].Reason
            }
            $item.ToRemove = ($item.Verdict -eq 'remove')
        }
        # The model holds ~12 GB of RAM; give it back before uninstallers and Windows Update run.
        Stop-LlmServer
    }

    Write-Info 'Choose what to KEEP. Programs marked REMOVE will be uninstalled; you can change any line.'
    $selected = Read-CleanupSelection -Items $items
    if ($null -eq $selected) { Write-Info 'Cleanup cancelled.'; return }

    if ($selected.Count) {
        Write-Host ''
        Write-Caution 'These will be uninstalled:'
        $selected | ForEach-Object { Write-Host ('   - {0}  ({1})' -f $_.Name, $_.Kind) }
        if (-not (Read-Confirmation -Prompt "Uninstall $($selected.Count) item(s)?")) {
            Write-Info 'Nothing was uninstalled.'
        }
        elseif (New-SafetyRestorePoint -Label 'USB AI Technician - before cleanup') {
            $results = foreach ($item in $selected) {
                Write-Info "Removing $($item.Name)..."
                $result = Remove-CleanupItem -Item $item
                if ($result.Success) { Write-Good "  $($result.Detail)" } else { Write-Problem "  $($result.Detail)" }
                $result
            }
            $failed = @($results | Where-Object { -not $_.Success })
            Write-Good ("Removed {0} of {1}." -f ($selected.Count - $failed.Count), $selected.Count)
            if ($failed.Count) { $failed | ForEach-Object { Write-Problem ("  Not removed: {0} ({1})" -f $_.Name, $_.Detail) } }
        }
    }
    else {
        Write-Info 'Nothing selected for removal.'
    }

    if (Get-Setting 'cleanup.offerTempCleanup' $true) {
        Write-Info 'Checking for old temporary files...'
        Clear-OldTempFiles
    }
}

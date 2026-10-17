# 3) Bring Windows fully up to date, then lock automatic updates down to security only.
#    Uses the Windows Update Agent COM API that ships with Windows, so nothing gets installed.

$script:RebootNeeded = $false

function Get-WindowsVersionInfo {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$cv.CurrentBuildNumber
    $version = if ($cv.DisplayVersion) { [string]$cv.DisplayVersion } else { [string]$cv.ReleaseId }
    [pscustomobject]@{
        Product = $(if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' })
        Version = $version
        Build = $build
    }
}

function Test-IsFeatureUpdate {
    param([string]$Title, [string[]]$CategoryNames)
    if ($CategoryNames -contains 'Upgrades') { return $true }
    return ($Title -match '^(Feature update to|Windows 1[01], version \d)')
}

# The registry policy that keeps monthly security (quality) updates automatic, but stops
# feature upgrades and driver updates. 'ManualOnly' turns automatic updating off entirely.
function Get-UpdatePolicyPlan {
    param(
        [ValidateSet('SecurityOnly', 'ManualOnly')][string]$Mode = 'SecurityOnly',
        [string]$Product,
        [string]$Version
    )
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $au = "$wu\AU"
    $plan = New-Object System.Collections.Generic.List[object]
    $add = {
        param($Path, $Name, $Value, $Type, $Why)
        $plan.Add([pscustomobject]@{ Path = $Path; Name = $Name; Value = $Value; Type = $Type; Why = $Why })
    }

    & $add $wu 'ExcludeWUDriversInQualityUpdate' 1 'DWord' 'no driver updates through Windows Update'
    if ($Product -and $Version) {
        & $add $wu 'TargetReleaseVersion' 1 'DWord' 'stay on the current Windows version'
        & $add $wu 'ProductVersion' $Product 'String' 'pinned product'
        & $add $wu 'TargetReleaseVersionInfo' $Version 'String' 'pinned version - no feature upgrades'
    }
    if ($Mode -eq 'SecurityOnly') {
        & $add $au 'NoAutoUpdate' 0 'DWord' 'keep automatic updates on for security fixes'
        & $add $au 'AUOptions' 4 'DWord' 'download and install security updates automatically'
        & $add $au 'ScheduledInstallDay' 0 'DWord' 'every day'
        & $add $au 'ScheduledInstallTime' 3 'DWord' 'at 03:00'
        & $add $au 'NoAutoRebootWithLoggedOnUsers' 1 'DWord' 'never force a restart while someone is signed in'
    }
    else {
        & $add $au 'NoAutoUpdate' 1 'DWord' 'turn automatic updates off completely'
    }
    return , $plan.ToArray()
}

function Get-UpdatePolicyBackupPath {
    $folder = Join-Path $script:Paths.Root 'backups'
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    return (Join-Path $folder ("update-policy-{0}.json" -f $env:COMPUTERNAME))
}

function Get-RegistryValueState {
    param([string]$Path, [string]$Name)
    if (Test-Path -LiteralPath $Path) {
        $key = Get-Item -LiteralPath $Path
        if ($key.GetValueNames() -contains $Name) {
            return [pscustomobject]@{ Existed = $true; Value = $key.GetValue($Name); Kind = $key.GetValueKind($Name).ToString() }
        }
    }
    return [pscustomobject]@{ Existed = $false; Value = $null; Kind = $null }
}

function Set-UpdatePolicy {
    param([Parameter(Mandatory)][object[]]$Plan)
    $backupFile = Get-UpdatePolicyBackupPath
    # Keep only the first backup per PC, so "undo" always returns to the original settings.
    if (-not (Test-Path -LiteralPath $backupFile) -and -not $script:DryRun) {
        $backup = foreach ($entry in $Plan) {
            $state = Get-RegistryValueState -Path $entry.Path -Name $entry.Name
            [pscustomobject]@{ Path = $entry.Path; Name = $entry.Name; Existed = $state.Existed; Value = $state.Value; Kind = $state.Kind }
        }
        ConvertTo-Json -InputObject @($backup) -Depth 4 | Set-Content -LiteralPath $backupFile -Encoding UTF8
        Write-Info "  Previous settings saved to $backupFile"
    }
    $failed = 0
    foreach ($entry in $Plan) {
        $ok = Invoke-Change -Description ('set {0}\{1} = {2}' -f $entry.Path, $entry.Name, $entry.Value) -Action {
            if (-not (Test-Path -LiteralPath $entry.Path)) { New-Item -Path $entry.Path -Force | Out-Null }
            New-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value $entry.Value -PropertyType $entry.Type -Force | Out-Null
        }
        if (-not $ok) { $failed++ }
    }
    return ($failed -eq 0)
}

function Restore-UpdatePolicy {
    Write-Heading 'Undo the update lock'
    $backupFile = Get-UpdatePolicyBackupPath
    if (Test-Path -LiteralPath $backupFile) {
        $parsed = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $backupFile -Raw -Encoding UTF8)
        $entries = @($parsed | ForEach-Object { $_ })
        Write-Info "Restoring the settings saved in $backupFile"
    }
    else {
        Write-Caution 'No backup for this PC on the USB - removing every value this tool can set.'
        $entries = @(
            (Get-UpdatePolicyPlan -Mode SecurityOnly -Product 'x' -Version 'x') + (Get-UpdatePolicyPlan -Mode ManualOnly -Product 'x' -Version 'x') |
                Sort-Object Path, Name -Unique |
                ForEach-Object { [pscustomobject]@{ Path = $_.Path; Name = $_.Name; Existed = $false; Value = $null; Kind = $null } }
        )
    }
    if (-not (Read-YesNo -Prompt 'Restore the original Windows Update behaviour?' -Default $true)) { return }
    foreach ($entry in $entries) {
        if ($entry.Existed) {
            [void](Invoke-Change -Description "restore $($entry.Path)\$($entry.Name)" -Action {
                New-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value $entry.Value -PropertyType $entry.Kind -Force | Out-Null
            })
        }
        elseif ((Get-RegistryValueState -Path $entry.Path -Name $entry.Name).Existed) {
            [void](Invoke-Change -Description "remove $($entry.Path)\$($entry.Name)" -Action {
                Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Force
            })
        }
    }
    if ((Test-Path -LiteralPath $backupFile) -and -not $script:DryRun) {
        Move-Item -LiteralPath $backupFile -Destination ($backupFile + ".restored-$(Get-Date -Format yyyyMMddHHmmss)") -Force
    }
    Write-Good 'Windows Update is back to how it was.'
}

function Show-UpdatePolicyPlan {
    param([object[]]$Plan)
    foreach ($entry in $Plan) {
        Write-Host ('   {0,-32} = {1,-12} {2}' -f $entry.Name, $entry.Value, $entry.Why) -ForegroundColor Gray
    }
}

function Install-PendingUpdates {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][object[]]$Updates)
    $collection = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($update in $Updates) {
        if (-not $update.EulaAccepted) { $update.AcceptEula() }
        [void]$collection.Add($update)
    }

    Write-Info ("Downloading {0} update(s). This can take a while..." -f $collection.Count)
    $downloader = $Session.CreateUpdateDownloader()
    $downloader.Updates = $collection
    [void]$downloader.Download()

    $ready = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($update in $Updates) { if ($update.IsDownloaded) { [void]$ready.Add($update) } }
    if ($ready.Count -eq 0) { Write-Problem 'Nothing could be downloaded.'; return }

    Write-Info ("Installing {0} update(s)..." -f $ready.Count)
    $installer = $Session.CreateUpdateInstaller()
    $installer.Updates = $ready
    $result = $installer.Install()
    for ($i = 0; $i -lt $ready.Count; $i++) {
        $code = $result.GetUpdateResult($i).ResultCode
        $title = $ready.Item($i).Title
        switch ($code) {
            2 { Write-Good "  OK      $title" }
            3 { Write-Caution "  PARTIAL $title" }
            default { Write-Problem "  FAILED  $title (result $code)" }
        }
    }
    if ($result.RebootRequired) { $script:RebootNeeded = $true }
}

function Start-WindowsUpdate {
    Write-Heading '3. Update Windows, then switch to security-only updates'
    $info = Get-WindowsVersionInfo
    Write-Info ("This PC: {0} {1} (build {2})" -f $info.Product, $info.Version, $info.Build)

    $service = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    if ($service -and $service.StartType -eq 'Disabled') {
        Write-Caution 'The Windows Update service is disabled on this PC.'
        if (-not (Read-YesNo -Prompt 'Set it back to Manual so updates can run?' -Default $true)) { return }
        [void](Invoke-Change -Description 'set wuauserv startup to Manual' -Action { Set-Service -Name wuauserv -StartupType Manual })
    }

    Write-Info 'Searching for updates (1-5 minutes)...'
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $session.ClientApplicationID = 'USB AI Technician'
        $searcher = $session.CreateUpdateSearcher()
        $found = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    }
    catch {
        Write-Problem "Windows Update search failed: $($_.Exception.Message)"
        return
    }

    $skipFeature = [bool](Get-Setting 'windowsUpdate.skipFeatureUpdates' $true)
    $updates = New-Object System.Collections.Generic.List[object]
    foreach ($update in $found.Updates) {
        $categories = @($update.Categories | ForEach-Object { $_.Name })
        if ($skipFeature -and (Test-IsFeatureUpdate -Title $update.Title -CategoryNames $categories)) {
            Write-Info "  skipping feature upgrade: $($update.Title)"
            continue
        }
        $updates.Add($update)
    }

    if ($updates.Count -eq 0) {
        Write-Good 'Windows is already up to date.'
    }
    else {
        for ($i = 0; $i -lt $updates.Count; $i++) {
            Write-Host ('  {0,-3} {1,-9} {2}' -f ($i + 1), (Format-Size $updates[$i].MaxDownloadSize), $updates[$i].Title)
        }
        $answer = (Read-Host '  Install which? (Enter = all, e.g. 1,3 / n = skip)').Trim()
        if ($answer -notin 'n', 'no') {
            try {
                $chosen = if ($answer) { @(ConvertTo-IndexList -Text $answer -Max $updates.Count | ForEach-Object { $updates[$_ - 1] }) } else { $updates.ToArray() }
                if ($script:DryRun) {
                    Write-Info "  [dry-run] would download and install $($chosen.Count) update(s)"
                }
                elseif (New-SafetyRestorePoint -Label 'USB AI Technician - before Windows Update') {
                    Install-PendingUpdates -Session $session -Updates $chosen
                }
            }
            catch {
                Write-Problem "Update failed: $($_.Exception.Message)"
            }
        }
    }

    # Step 2: lock it down.
    $mode = [string](Get-Setting 'windowsUpdate.mode' 'SecurityOnly')
    $plan = Get-UpdatePolicyPlan -Mode $mode -Product $info.Product -Version $info.Version
    Write-Host ''
    if ($mode -eq 'SecurityOnly') {
        Write-Info 'Next: turn off automatic feature upgrades and driver updates, keep monthly security updates automatic.'
    }
    else {
        Write-Info 'Next: turn automatic updates OFF completely (ManualOnly mode from settings.json).'
    }
    Show-UpdatePolicyPlan -Plan $plan
    if (Read-YesNo -Prompt 'Apply these Windows Update settings?' -Default $true) {
        if (Set-UpdatePolicy -Plan $plan) { Write-Good 'Update policy applied. Menu option 6 undoes it.' }
    }
    if ($script:RebootNeeded) { Write-Caution 'A restart is needed to finish installing updates.' }
}

<#
.SYNOPSIS
    Dependency-free tests for the pure logic (parsing, decisions, policy plans) plus an
    end-to-end check of the AI client against a fake OpenAI-compatible server.
    Runs on Windows PowerShell 5.1 and PowerShell 7. Changes nothing on the PC.
#>
$ErrorActionPreference = 'Stop'
$src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
foreach ($lib in 'Common', 'Llm', 'Cleanup', 'Installers', 'WindowsUpdate') { . (Join-Path $src "lib\$lib.ps1") }

$script:Paths = @{ Root = (Split-Path -Parent $PSScriptRoot); Config = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config') }
$script:Settings = [pscustomobject]@{ llm = [pscustomobject]@{ contextSize = 4096; reasoningEffort = 'low' } }
$script:LogFile = $null
$script:Failures = 0
$script:Passed = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    }
    catch {
        $script:Failures++
        Write-Host "  FAIL  $Name - $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if ($Expected -is [array] -or $Actual -is [array]) {
        $e = @($Expected) -join ','
        $a = @($Actual) -join ','
        if ($e -ne $a) { throw "expected [$e] but got [$a] $Message" }
        return
    }
    if ($Expected -ne $Actual) { throw "expected '$Expected' but got '$Actual' $Message" }
}

function Assert-Throws {
    param([scriptblock]$Body)
    $threw = $false
    try { & $Body } catch { $threw = $true }
    if (-not $threw) { throw 'expected an error but none was thrown' }
}

Write-Host "`nCommon" -ForegroundColor Cyan
Test-Case 'index list parses numbers and ranges' { Assert-Equal @(1, 3, 4, 5, 9) (ConvertTo-IndexList -Text '9, 3-5 1' -Max 10) }
Test-Case 'index list accepts reversed ranges and removes duplicates' { Assert-Equal @(2, 3, 4) (ConvertTo-IndexList -Text '4-2,3' -Max 5) }
Test-Case 'index list rejects out of range' { Assert-Throws { ConvertTo-IndexList -Text '0' -Max 5 }; Assert-Throws { ConvertTo-IndexList -Text '2-6' -Max 5 } }
Test-Case 'index list rejects words' { Assert-Throws { ConvertTo-IndexList -Text 'abc' -Max 5 } }
Test-Case 'single index stays an array' { Assert-Equal 1 @(ConvertTo-IndexList -Text '2' -Max 5).Count }
Test-Case 'format size' { Assert-Equal '1.5 GB' (Format-Size (1.5GB)); Assert-Equal '-' (Format-Size 0) }
Test-Case 'limit text pads and truncates' { Assert-Equal 'ab   ' (Limit-Text 'ab' 5); Assert-Equal 'abcd~' (Limit-Text 'abcdefgh' 5) }
Test-Case 'nested setting lookup with default' {
    Assert-Equal 4096 (Get-Setting 'llm.contextSize' 1)
    Assert-Equal 'x' (Get-Setting 'llm.missing' 'x')
    Assert-Equal 'y' (Get-Setting 'nothing.here' 'y')
}

Write-Host "`nAI output parsing" -ForegroundColor Cyan
Test-Case 'extracts JSON array from prose and code fences' {
    $text = "Sure! Here you go:`n``````json`n[{""id"":1,""verdict"":""remove"",""reason"":""trial [ad] {x}""}]`n``````"
    $json = @(Get-JsonFromText $text)
    Assert-Equal 1 $json.Count
    Assert-Equal 'trial [ad] {x}' $json[0].reason
}
Test-Case 'skips broken JSON and finds the next valid one' {
    $json = @(Get-JsonFromText 'bad [1,2 then {"id":3}')
    Assert-Equal 3 $json[0].id
}
Test-Case 'returns null when there is no JSON' { Assert-Equal $null (Get-JsonFromText 'no json here') }
Test-Case 'verdicts ignore unknown ids and normalise bad verdicts' {
    $text = '[{"id":1,"verdict":"REMOVE","reason":"bloat"},{"id":2,"verdict":"delete!","reason":"?"},{"id":99,"verdict":"keep"}]'
    $v = ConvertTo-ProgramVerdicts -Text $text -ValidIds 1, 2
    Assert-Equal 2 $v.Count
    Assert-Equal 'remove' $v[1].Verdict
    Assert-Equal 'ask' $v[2].Verdict
}

Write-Host "`nCleanup" -ForegroundColor Cyan
Test-Case 'quiet uninstall string wins' {
    $c = Get-UninstallCommand -UninstallString 'x.exe' -QuietUninstallString '"C:\P F\u.exe" /S'
    Assert-Equal 'cmd.exe' $c.FilePath
    Assert-Equal '/c ""C:\P F\u.exe" /S"' $c.Arguments
    Assert-Equal $true $c.Silent
}
Test-Case 'MSI entries uninstall silently by product code' {
    $c = Get-UninstallCommand -UninstallString 'MsiExec.exe /I{12345678-ABCD-1234-ABCD-1234567890AB}'
    Assert-Equal 'msiexec.exe' $c.FilePath
    Assert-Equal '/x {12345678-ABCD-1234-ABCD-1234567890AB} /qn /norestart' $c.Arguments
}
Test-Case 'other uninstallers run interactively' {
    $c = Get-UninstallCommand -UninstallString '"C:\App\uninstall.exe"'
    Assert-Equal $false $c.Silent
}
Test-Case 'protected patterns from config keep drivers and runtimes' {
    $p = Get-ProtectedPatterns
    Assert-Equal $true (Test-MatchesAny 'Microsoft Visual C++ 2015-2022 Redistributable (x64)' $p.programNamePatterns)
    Assert-Equal $true (Test-MatchesAny 'NVIDIA Graphics Driver 560.94' $p.programNamePatterns)
    Assert-Equal $true (Test-MatchesAny 'Microsoft.VCLibs.140.00' $p.storeNamePatterns)
    Assert-Equal $false (Test-MatchesAny 'McAfee LiveSafe' $p.programNamePatterns)
    Assert-Equal $false (Test-MatchesAny 'Microsoft.BingNews' $p.storeNamePatterns)
}

Write-Host "`nInstallers" -ForegroundColor Cyan
$ascii = [Text.Encoding]::ASCII
Test-Case 'detects Inno Setup' { Assert-Equal 'inno' (Get-InstallerTypeFromBytes $ascii.GetBytes('MZ....Inno Setup Setup Data (6.2.0)')) }
Test-Case 'detects NSIS' { Assert-Equal 'nsis' (Get-InstallerTypeFromBytes $ascii.GetBytes('MZ..Nullsoft.NSIS.exehead')) }
Test-Case 'detects WiX Burn' { Assert-Equal 'wix' (Get-InstallerTypeFromBytes $ascii.GetBytes('MZ..PE...wixburn')) }
Test-Case 'unknown stays unknown' { Assert-Equal 'unknown' (Get-InstallerTypeFromBytes $ascii.GetBytes('MZ plain exe')) }
Test-Case 'msi installs silently' {
    $c = Get-InstallCommand -Path 'E:\Installers\a b.msi' -Type 'msi'
    Assert-Equal 'msiexec.exe' $c.FilePath
    Assert-Equal '/i "E:\Installers\a b.msi" /qn /norestart' $c.Arguments
}
Test-Case 'override args beat detection, interactive override wins' {
    $c = Get-InstallCommand -Path 'x.exe' -Type 'nsis' -Override ([pscustomobject]@{ file = 'x.exe'; args = '/silent /install' })
    Assert-Equal '/silent /install' $c.Arguments
    $c = Get-InstallCommand -Path 'x.exe' -Type 'nsis' -Override ([pscustomobject]@{ file = 'x.exe'; interactive = $true })
    Assert-Equal $false $c.Silent
}
Test-Case 'unknown exe opens its window' { Assert-Equal $false (Get-InstallCommand -Path 'x.exe' -Type 'unknown').Silent }

Write-Host "`nWindows Update" -ForegroundColor Cyan
Test-Case 'feature updates are recognised' {
    Assert-Equal $true (Test-IsFeatureUpdate -Title 'Feature update to Windows 11, version 25H2' -CategoryNames @())
    Assert-Equal $true (Test-IsFeatureUpdate -Title 'Something' -CategoryNames @('Upgrades'))
    Assert-Equal $false (Test-IsFeatureUpdate -Title '2026-10 Cumulative Update for Windows 11 Version 24H2 (KB5099999)' -CategoryNames @('Security Updates'))
}
Test-Case 'security-only plan pins the version and keeps security updates automatic' {
    $plan = Get-UpdatePolicyPlan -Mode SecurityOnly -Product 'Windows 11' -Version '24H2'
    $byName = @{}; $plan | ForEach-Object { $byName[$_.Name] = $_.Value }
    Assert-Equal 1 $byName['TargetReleaseVersion']
    Assert-Equal '24H2' $byName['TargetReleaseVersionInfo']
    Assert-Equal 'Windows 11' $byName['ProductVersion']
    Assert-Equal 1 $byName['ExcludeWUDriversInQualityUpdate']
    Assert-Equal 0 $byName['NoAutoUpdate']
    Assert-Equal 4 $byName['AUOptions']
}
Test-Case 'manual-only plan turns automatic updates off' {
    $plan = Get-UpdatePolicyPlan -Mode ManualOnly -Product 'Windows 10' -Version '22H2'
    Assert-Equal 1 ($plan | Where-Object Name -eq 'NoAutoUpdate').Value
    Assert-Equal 0 @($plan | Where-Object Name -eq 'AUOptions').Count
}
Test-Case 'no version pin when the version is unknown' {
    $plan = Get-UpdatePolicyPlan -Mode SecurityOnly -Product 'Windows 10' -Version ''
    Assert-Equal 0 @($plan | Where-Object Name -like 'TargetRelease*').Count
}

Write-Host "`nAI client against a fake llama-server" -ForegroundColor Cyan
$port = Get-FreeTcpPort
$server = Start-Job -ArgumentList $port -ScriptBlock {
    param($port)
    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$port/")
    $listener.Start()
    try {
        for ($i = 0; $i -lt 2; $i++) {
            $ctx = $listener.GetContext()
            $reader = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
            $request = $reader.ReadToEnd() | ConvertFrom-Json
            $prompt = $request.messages[-1].content
            $content = if ($prompt -match 'Programs \(id') {
                "Here is my review:`n[{`"id`":1,`"verdict`":`"remove`",`"reason`":`"OEM trialware`"},{`"id`":2,`"verdict`":`"keep`",`"reason`":`"browser`"}]"
            } else {
                "echo: $prompt"
            }
            $body = @{ choices = @(@{ message = @{ role = 'assistant'; content = $content } }) } | ConvertTo-Json -Depth 5
            $bytes = [Text.Encoding]::UTF8.GetBytes($body)
            $ctx.Response.ContentType = 'application/json; charset=utf-8'
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.Close()
        }
    }
    finally { $listener.Stop() }
}
Start-Sleep -Seconds 2
$script:LlmUrl = "http://127.0.0.1:$port"
Test-Case 'chat round-trip keeps non-ASCII text intact' {
    $answer = Invoke-LlmChat -Messages @(@{ role = 'user'; content = "shalom $([char]0x05E9)$([char]0x05DC)$([char]0x05D5)$([char]0x05DD)" })
    Assert-Equal "echo: shalom $([char]0x05E9)$([char]0x05DC)$([char]0x05D5)$([char]0x05DD)" $answer
}
Test-Case 'program review end to end' {
    $items = @(
        [pscustomobject]@{ Number = 1; Name = 'Vendor Trial Suite'; Publisher = 'OEM'; Kind = 'Program' },
        [pscustomobject]@{ Number = 2; Name = 'Mozilla Firefox'; Publisher = 'Mozilla'; Kind = 'Program' }
    )
    $v = Get-AiProgramVerdicts -Items $items
    Assert-Equal 'remove' $v[1].Verdict
    Assert-Equal 'keep' $v[2].Verdict
}
$server | Wait-Job -Timeout 10 | Out-Null
$server | Remove-Job -Force

Write-Host ''
if ($script:Failures) {
    Write-Host "$script:Failures failed, $script:Passed passed" -ForegroundColor Red
    exit 1
}
Write-Host "All $script:Passed tests passed" -ForegroundColor Green

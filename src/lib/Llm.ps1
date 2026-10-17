# Local AI: runs llama.cpp's llama-server from the USB with gpt-oss-20b and talks to it
# over its OpenAI-compatible HTTP API on 127.0.0.1 only. Nothing is sent to the internet.
#
# The model only ever *suggests*. Every change it proposes is shown to the user and
# needs explicit confirmation; it cannot run commands by itself.

$script:LlmProcess = $null
$script:LlmUrl = $null

function Get-LlmServerPath {
    $path = Join-Path $script:Paths.Root (Get-Setting 'llm.serverExe' 'bin\llama-server.exe')
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Get-LlmModelPath {
    $path = Join-Path $script:Paths.Root (Get-Setting 'llm.modelFile' 'models\gpt-oss-20b-MXFP4.gguf')
    if (Test-Path -LiteralPath $path) { return $path }
    # Fall back to any GGUF the user dropped into models\
    $any = Get-ChildItem -LiteralPath $script:Paths.Models -Filter '*.gguf' -File -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First 1
    if ($any) { return $any.FullName }
    return $null
}

# Returns $null when the AI can be used, otherwise the reason it cannot.
function Get-AiUnavailableReason {
    if ($script:NoAI) { return 'started with -NoAI' }
    if (-not (Get-Setting 'llm.enabled' $true)) { return 'disabled in config\settings.json' }
    if (-not (Get-LlmServerPath)) { return 'llama-server.exe not found in bin\ (run Setup-USB.ps1)' }
    if (-not (Get-LlmModelPath)) { return 'model file not found in models\ (run Setup-USB.ps1)' }
    return $null
}

function Get-FreeTcpPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return $listener.LocalEndpoint.Port }
    finally { $listener.Stop() }
}

function Start-LlmServer {
    if ($script:LlmProcess -and -not $script:LlmProcess.HasExited) { return $true }

    $reason = Get-AiUnavailableReason
    if ($reason) {
        Write-Caution "AI technician not available: $reason. Continuing without AI suggestions."
        return $false
    }

    $exe = Get-LlmServerPath
    $model = Get-LlmModelPath
    $port = Get-FreeTcpPort
    $arguments = @(
        '-m', ('"{0}"' -f $model),
        '--host', '127.0.0.1',
        '--port', $port,
        '-c', [int](Get-Setting 'llm.contextSize' 8192),
        '--jinja'
    ) + @(Get-Setting 'llm.extraArgs' @())

    $outLog = Join-Path $script:Paths.Logs 'llama-server.out.log'
    $errLog = Join-Path $script:Paths.Logs 'llama-server.err.log'
    Write-Info ("Starting the AI technician ({0})..." -f (Split-Path -Leaf $model))
    Write-AppLog ("llama-server {0}" -f ($arguments -join ' '))

    $script:LlmProcess = Start-Process -FilePath $exe -ArgumentList ($arguments -join ' ') `
        -WorkingDirectory (Split-Path -Parent $exe) -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $script:LlmUrl = "http://127.0.0.1:$port"

    $timeout = [int](Get-Setting 'llm.startupTimeoutSeconds' 900)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Write-Host '  Loading the model from the USB drive (a USB 3 stick takes 1-3 minutes)' -NoNewline
    while ($watch.Elapsed.TotalSeconds -lt $timeout) {
        if ($script:LlmProcess.HasExited) {
            Write-Host ''
            Write-Problem "  The AI server stopped while loading. Last lines of $errLog :"
            Get-Content -LiteralPath $errLog -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            $script:LlmProcess = $null
            return $false
        }
        try {
            $health = Invoke-RestMethod -Uri "$script:LlmUrl/health" -TimeoutSec 5 -ErrorAction Stop
            if ($health.status -eq 'ok') {
                Write-Host ''
                Write-Good ("  AI technician ready ({0:N0}s)." -f $watch.Elapsed.TotalSeconds)
                return $true
            }
        }
        catch {
            # 503 while the model is still loading
        }
        Write-Host '.' -NoNewline
        Start-Sleep -Seconds 3
    }
    Write-Host ''
    Write-Problem '  The AI server did not become ready in time.'
    Stop-LlmServer
    return $false
}

function Stop-LlmServer {
    if ($script:LlmProcess -and -not $script:LlmProcess.HasExited) {
        & taskkill.exe /PID $script:LlmProcess.Id /T /F 2>&1 | Out-Null
        Write-AppLog 'llama-server stopped'
    }
    $script:LlmProcess = $null
}

function Invoke-LlmChat {
    param(
        [Parameter(Mandatory)][object[]]$Messages,
        [int]$MaxTokens = 2048,
        [double]$Temperature = 0.2
    )
    if (-not $script:LlmUrl) { throw 'AI server is not running.' }
    $body = @{
        messages = $Messages
        max_tokens = $MaxTokens
        temperature = $Temperature
        stream = $false
        # gpt-oss supports low/medium/high reasoning; low keeps it fast on ordinary PCs.
        chat_template_kwargs = @{ reasoning_effort = (Get-Setting 'llm.reasoningEffort' 'low') }
    }
    $json = ConvertTo-Json -InputObject $body -Depth 8 -Compress
    $response = Invoke-RestMethod -Uri "$script:LlmUrl/v1/chat/completions" -Method Post `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) `
        -TimeoutSec 900 -ErrorAction Stop
    return [string]$response.choices[0].message.content
}

# ---------------------------------------------------------------- parsing model output

# Index of the bracket that closes the JSON value starting at $Start, or -1.
function Find-JsonEnd {
    param([string]$Text, [int]$Start)
    $depth = 0
    $inString = $false
    $escape = $false
    for ($i = $Start; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($inString) {
            if ($escape) { $escape = $false }
            elseif ($c -eq '\') { $escape = $true }
            elseif ($c -eq '"') { $inString = $false }
            continue
        }
        if ($c -eq '"') { $inString = $true }
        elseif ($c -eq '[' -or $c -eq '{') { $depth++ }
        elseif ($c -eq ']' -or $c -eq '}') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }
    return -1
}

# Pulls the first valid JSON array/object out of free text (models like to add prose or ``` fences).
function Get-JsonFromText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $from = 0
    while ($from -lt $Text.Length) {
        $start = $Text.IndexOfAny([char[]]'[{', $from)
        if ($start -lt 0) { return $null }
        $end = Find-JsonEnd -Text $Text -Start $start
        if ($end -gt $start) {
            try { return (ConvertFrom-Json -InputObject $Text.Substring($start, $end - $start + 1)) }
            catch { }
        }
        $from = $start + 1
    }
    return $null
}

# Turns the model's answer into @{ <number> = { Verdict; Reason } }, dropping anything invalid.
function ConvertTo-ProgramVerdicts {
    param([string]$Text, [int[]]$ValidIds)
    $result = @{}
    $rows = @(Get-JsonFromText -Text $Text)
    foreach ($row in $rows) {
        if ($null -eq $row -or -not $row.PSObject.Properties['id']) { continue }
        $id = 0
        if (-not [int]::TryParse([string]$row.id, [ref]$id)) { continue }
        if ($ValidIds -notcontains $id) { continue }
        $verdict = ([string]$row.verdict).Trim().ToLowerInvariant()
        if ($verdict -notin 'remove', 'keep', 'ask') { $verdict = 'ask' }
        $reason = ([string]$row.reason).Trim()
        if ($reason.Length -gt 60) { $reason = $reason.Substring(0, 60) }
        $result[$id] = [pscustomobject]@{ Verdict = $verdict; Reason = $reason }
    }
    return $result
}

$script:CleanupSystemPrompt = @'
You are a careful Windows PC technician helping a user clean up their computer.
You classify installed software. You only give advice; the user makes the final decision.
Reply with JSON only.
'@

function Get-AiProgramVerdicts {
    param([Parameter(Mandatory)][object[]]$Items, [int]$BatchSize = 25)
    $verdicts = @{}
    for ($i = 0; $i -lt $Items.Count; $i += $BatchSize) {
        $last = [Math]::Min($i + $BatchSize, $Items.Count) - 1
        $batch = @($Items[$i..$last])
        $lines = $batch | ForEach-Object { '{0} | {1} | {2} | {3}' -f $_.Number, $_.Name, $_.Publisher, $_.Kind }
        $prompt = @"
For each program below decide:
- "remove": clearly unwanted for a normal user (manufacturer promo/bloatware, trialware, toolbars, adware, junk "optimizers", expired bundled trial antivirus, games that came preinstalled)
- "keep": drivers, runtimes, security software, browsers, office/productivity, creative, developer and gaming tools, anything a normal user likely relies on
- "ask": not sure, or depends on the user
Never answer "remove" for drivers, runtimes, redistributables or the only security software. When unsure answer "ask".

Answer ONLY with a JSON array like:
[{"id":1,"verdict":"remove","reason":"OEM trial software"}]
"reason" must be at most 8 words.

Programs (id | name | publisher | type):
$($lines -join "`n")
"@
        Write-Host ('  AI is reviewing programs {0}-{1} of {2}...' -f ($i + 1), ($last + 1), $Items.Count)
        try {
            $answer = Invoke-LlmChat -MaxTokens 4096 -Messages @(
                @{ role = 'system'; content = $script:CleanupSystemPrompt },
                @{ role = 'user'; content = $prompt }
            )
            $parsed = ConvertTo-ProgramVerdicts -Text $answer -ValidIds ($batch | ForEach-Object { $_.Number })
            foreach ($key in $parsed.Keys) { $verdicts[$key] = $parsed[$key] }
            if ($parsed.Count -lt $batch.Count) {
                Write-AppLog ("AI answered for {0} of {1} programs in this batch" -f $parsed.Count, $batch.Count) -Level WARN
            }
        }
        catch {
            Write-Caution "  AI review failed for this batch: $($_.Exception.Message)"
        }
    }
    return $verdicts
}

# Free-form Q&A with the technician. Advice only - it cannot execute anything.
function Start-AiChat {
    if (-not (Start-LlmServer)) { return }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $system = @"
You are an experienced, friendly Windows PC technician running locally from a USB stick.
The PC runs $($os.Caption) (build $($os.BuildNumber)).
You can only give advice and explain things; you cannot run commands on the PC.
If the user wants to clean the PC, install programs from the USB or update Windows, tell them to use
menu options 1, 2 or 3 of this tool. Answer briefly, in the same language the user writes in.
"@
    $messages = New-Object System.Collections.ArrayList
    [void]$messages.Add(@{ role = 'system'; content = $system })
    Write-Heading 'Ask the AI technician (empty line = back to menu)'
    while ($true) {
        $question = Read-Host 'you'
        if ([string]::IsNullOrWhiteSpace($question)) { break }
        [void]$messages.Add(@{ role = 'user'; content = $question })
        try {
            $answer = Invoke-LlmChat -Messages $messages.ToArray() -MaxTokens 2048 -Temperature 0.6
            [void]$messages.Add(@{ role = 'assistant'; content = $answer })
            Write-Host ''
            Write-Host $answer -ForegroundColor Cyan
            Write-Host ''
        }
        catch {
            Write-Problem "AI error: $($_.Exception.Message)"
            $messages.RemoveAt($messages.Count - 1)
        }
    }
}

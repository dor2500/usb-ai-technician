<#
.SYNOPSIS
    Renders a text "screen" into a terminal-style SVG for the README.
    Colour markup inside the text: [[green]]text[[/]]  (default, dim, cyan, green, yellow, red, white, hl)
.EXAMPLE
    .\tools\New-TerminalSvg.ps1 -InputFile docs\screens\menu.txt -OutFile docs\images\screen-menu.svg -Title 'Start.cmd'
#>
param(
    [Parameter(Mandatory)][string]$InputFile,
    [Parameter(Mandatory)][string]$OutFile,
    [string]$Title = 'Administrator: USB AI Technician'
)

$colors = @{
    default = '#d4d4d4'; dim = '#7a828e'; cyan = '#4fc1ff'; green = '#4ec96b'
    yellow = '#e5c07b'; red = '#f47174'; white = '#ffffff'; hl = '#ffd866'
}
$fontSize = 14
$lineHeight = 20
$charWidth = 8.45
$padX = 22
$top = 52

$lines = @(Get-Content -LiteralPath $InputFile -Encoding UTF8)
$plainWidth = ($lines | ForEach-Object { ($_ -replace '\[\[[a-z/]+\]\]', '').Length } | Measure-Object -Maximum).Maximum
$width = [int][Math]::Ceiling([Math]::Max(640, $plainWidth * $charWidth + 2 * $padX))
$height = $top + $lines.Count * $lineHeight + 18

function ConvertTo-XmlText([string]$s) { [Security.SecurityElement]::Escape($s) }

$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f $width, $height))
[void]$sb.AppendLine('  <rect width="100%" height="100%" rx="10" fill="#0c0c0c"/>')
[void]$sb.AppendLine(('  <rect width="{0}" height="34" rx="10" fill="#1f1f1f"/><rect y="24" width="{0}" height="10" fill="#1f1f1f"/>' -f $width))
[void]$sb.AppendLine('  <circle cx="20" cy="17" r="6" fill="#ff5f57"/><circle cx="40" cy="17" r="6" fill="#febc2e"/><circle cx="60" cy="17" r="6" fill="#28c840"/>')
[void]$sb.AppendLine(('  <text x="{0}" y="22" fill="#9da5b4" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="13" text-anchor="middle">{1}</text>' -f ($width / 2), (ConvertTo-XmlText $Title)))
[void]$sb.AppendLine(('  <g font-family="Cascadia Mono, Consolas, Menlo, monospace" font-size="{0}">' -f $fontSize))

$y = $top
$color = 'default'   # a colour carries over to following lines until [[/]]
foreach ($line in $lines) {
    $parts = [regex]::Split($line, '(\[\[[a-z/]+\]\])')
    $spans = New-Object Text.StringBuilder
    foreach ($part in $parts) {
        if ($part -match '^\[\[([a-z/]+)\]\]$') {
            $color = if ($Matches[1] -eq '/') { 'default' } else { $Matches[1] }
            continue
        }
        if ($part) { [void]$spans.Append(('<tspan fill="{0}">{1}</tspan>' -f $colors[$color], (ConvertTo-XmlText $part))) }
    }
    [void]$sb.AppendLine(('    <text x="{0}" y="{1}" xml:space="preserve">{2}</text>' -f $padX, $y, $spans.ToString()))
    $y += $lineHeight
}
[void]$sb.AppendLine('  </g>')
[void]$sb.AppendLine('</svg>')
[IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
Write-Host "Wrote $OutFile ($width x $height)"

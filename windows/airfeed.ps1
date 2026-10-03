# AirFeed test rig for the Windows laptop: one setup step and one guided test of about
# five minutes that covers every hardware experiment.
#
# This is NOT the production receiver. It has no safety gate, so damaged frames and the
# Windows desktop can reach the HDMI output. Do not put it on a live programme.
#
# Start it by double-clicking airfeed.cmd, or:
#   powershell -ExecutionPolicy Bypass -File airfeed.ps1
# Written for Windows PowerShell 5.1 (the one built into Windows). ASCII only.
param(
    [string]$Run,     # setup | test : run one step and exit
    [switch]$Quick    # dry run: 3 second phases, no "press Enter" (also used by the automated check)
)

# Knobs
$Port      = 9000      # UDP port the iPhone sends SRT to (the port after it is used on this laptop only)
$LatencyMs = 120       # SRT receive buffer. Raise if the picture breaks up, lower to cut delay.
$Bitrate   = 6000000   # video bitrate written into the iPhone config
$Probe     = 32768     # bytes ffplay reads before it starts. If the video window never opens, try 1000000.
$PatternSeconds  = 15
$ClockSeconds    = 25
$PositionSeconds = 45
$ReturnSeconds   = 15
$Positions = @(
    'close to the router',
    'the middle of the hall',
    'the far end of the hall',
    'the worst spot you would ever film from'
)
if ($Quick) { $PatternSeconds = $ClockSeconds = $PositionSeconds = $ReturnSeconds = 3 }

$Captures = Join-Path $PSScriptRoot 'captures'
$Config   = Join-Path $PSScriptRoot 'airfeed-windows.xml'
# ffmpeg's SRT latency option is in microseconds
$SrtUrl   = "srt://0.0.0.0:${Port}?mode=listener&latency=$($LatencyMs * 1000)"
$LocalUrl = "udp://127.0.0.1:$($Port + 1)"

# Rows of the test pattern as fractions of the screen: 75% colour bars, grey steps,
# then near black and near white steps. A correct chain records RGB 0 as luma 16 and
# RGB 255 as luma 235 with every step distinct.
$PatternRows = @(
    @{ Top = 0.0; Height = 0.4; Colours = @(@(191,191,191), @(191,191,0), @(0,191,191), @(0,191,0), @(191,0,191), @(191,0,0), @(0,0,191), @(0,0,0)) },
    @{ Top = 0.4; Height = 0.3; Colours = @(0,26,51,77,102,128,153,179,204,230,255 | ForEach-Object { ,@($_, $_, $_) }) },
    @{ Top = 0.7; Height = 0.3; Colours = @(0,2,4,6,8,12,16,24,231,239,243,247,249,251,253,255 | ForEach-Object { ,@($_, $_, $_) }) }
)

function Test-Ffmpeg {
    foreach ($tool in 'ffmpeg', 'ffplay', 'ffprobe') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { return $false }
    }
    return [bool]((& ffmpeg -hide_banner -protocols) -match '^\s*srt$')
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LanAddress {
    Get-NetIPConfiguration |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        ForEach-Object { [pscustomobject]@{ Name = $_.InterfaceAlias; Address = $_.IPv4Address[0].IPAddress } }
}

function Invoke-Setup {
    Write-Host "`n== Setup =="

    if (Test-Ffmpeg) {
        Write-Host 'ffmpeg with SRT support: found'
    } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host 'Installing ffmpeg (gyan.dev essentials build) with winget...'
        winget install "FFmpeg (Essentials Build)" --accept-source-agreements --accept-package-agreements
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
        if (-not (Test-Ffmpeg)) {
            Write-Host 'ffmpeg still not found. Close this window, start the script again and run setup once more.' -ForegroundColor Red
            return
        }
    } else {
        Write-Host 'ffmpeg is missing and winget is not available.' -ForegroundColor Red
        Write-Host 'Download the essentials build from https://www.gyan.dev/ffmpeg/builds/ , unzip it,'
        Write-Host 'add its bin folder to PATH, then run setup again.'
        return
    }

    $rule = "AirFeed SRT $Port"
    if (-not (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
        Write-Host "Opening UDP port $Port to devices on your local network. Windows may ask for permission."
        $cmd = "New-NetFirewallRule -DisplayName '$rule' -Direction Inbound -Protocol UDP -LocalPort $Port -RemoteAddress LocalSubnet -Action Allow"
        try {
            if (Test-Admin) { Invoke-Expression $cmd | Out-Null }
            else { Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -Command $cmd" }
        } catch {
            Write-Host "Could not add the rule: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue) {
        Write-Host "Firewall rule '$rule': present (remove later with: Remove-NetFirewallRule -DisplayName '$rule')"
    } else {
        Write-Host 'No firewall rule. If Windows asks about ffmpeg later, choose Allow.' -ForegroundColor Yellow
    }

    $lan = @(Get-LanAddress)
    if (-not $lan) {
        Write-Host 'No network connection with a gateway found. Connect the laptop to the router and run setup again.' -ForegroundColor Red
        return
    }
    $lan | ForEach-Object { Write-Host ("Network: {0}  {1}" -f $_.Address, $_.Name) }
    $ip = $lan[0].Address
    if ($lan[0].Name -match 'Wi-?Fi|Wireless') {
        Write-Host 'This is a WiFi connection. The plan is Ethernet for the laptop, so only the iPhone is wireless.' -ForegroundColor Yellow
    }

    # Schema from an unofficial blog (glyph.sh), not from Blackmagic. If the app rejects it, that is a finding.
    $xml = @"
<?xml version="1.0" encoding="UTF-8" ?>
<streaming>
    <service>
        <name>AirFeed Windows</name>
        <servers>
            <server>
                <name>Laptop</name>
                <url>srt://${ip}:${Port}</url>
            </server>
        </servers>
        <profiles>
            <profile>
                <name>AirFeed low latency</name>
                <low-latency/>
                <config resolution="HD">
                    <bitrate>$Bitrate</bitrate>
                    <audio-bitrate>128000</audio-bitrate>
                    <keyframe-interval>2</keyframe-interval>
                </config>
            </profile>
            <profile>
                <name>AirFeed standard</name>
                <config resolution="HD">
                    <bitrate>$Bitrate</bitrate>
                    <audio-bitrate>128000</audio-bitrate>
                    <keyframe-interval>2</keyframe-interval>
                </config>
            </profile>
        </profiles>
    </service>
</streaming>
"@
    [IO.File]::WriteAllText($Config, $xml)

    Write-Host @"

iPhone config written to:
  $Config
It points the iPhone at srt://${ip}:${Port}. Run setup again if the laptop's address changes.

Before the guided test
  1. Get that file onto the iPhone (email it to yourself, or use iCloud Drive or OneDrive)
     and save it in the Files app.
  2. In Blackmagic Camera (3.2 or later): settings, streaming, import the file as a custom
     service. These menu names are unverified.
  3. Choose service "AirFeed Windows", profile "AirFeed low latency". Set the frame rate
     to the ATEM's video standard. Do not start streaming yet.
  4. Connect the laptop's HDMI output to an ATEM input and put that input on programme.
     In Windows display settings choose Extend, 1920 x 1080, scale 100%, refresh rate equal
     to the ATEM's video standard, HDR and Night light off.
  5. Turn the laptop's volume up: the test tells you out loud when to move.
"@
}

function Say($text) {
    Write-Host "`n>>> $text" -ForegroundColor Cyan
    try { [console]::Beep(880, 250) } catch { }
    if ($script:Voice) { try { $script:Voice.SpeakAsync($text) | Out-Null } catch { } }
}

function Get-Size($path) {
    try {
        $s = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $n = $s.Length
        $s.Close()
        return $n
    } catch { return 0 }
}

function Save-Screenshot($path) {
    try {
        $v = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap $v.Width, $v.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($v.Location, [System.Drawing.Point]::Empty, $v.Size)
        $bmp.Save($path)
        $g.Dispose()
        $bmp.Dispose()
        Write-Host "Screenshot: $path"
    } catch {
        Write-Host "Screenshot failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Waits while keeping the windows alive, the clock running and an eye on the capture file.
# Returns the longest time the file did not grow (a stall) and the bytes received.
function Wait-Phase($seconds, $file, $shots) {
    $start = $script:Watch.Elapsed.TotalSeconds
    $size0 = $lastSize = Get-Size $file
    $lastGrow = $nextSample = $start
    $longest = 0.0
    $shots = @($shots)
    while ($true) {
        $now = $script:Watch.Elapsed.TotalSeconds
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:ClockLabel) { $script:ClockLabel.Text = '{0:00.000}' -f ($now % 100) }
        if ($file -and $now -ge $nextSample) {
            $nextSample = $now + 0.25
            $size = Get-Size $file
            if ($size -gt $lastSize) {
                $longest = [math]::Max($longest, $now - $lastGrow)
                $lastSize = $size
                $lastGrow = $now
            }
        }
        if ($shots -and $now -ge $start + $shots[0]) {
            Save-Screenshot (Join-Path $Captures ("latency-{0}-{1}.png" -f $script:Stamp, [int]$shots[0]))
            $shots = @($shots | Select-Object -Skip 1)
        }
        if ($now -ge $start + $seconds) { break }
        Start-Sleep -Milliseconds 10
    }
    $longest = [math]::Max($longest, $now - $lastGrow)
    return [pscustomobject]@{ Stall = $longest; Bytes = $lastSize - $size0 }
}

function Show-Pattern($bounds) {
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'Manual'
    $form.Bounds = $bounds
    $form.TopMost = $true
    $form.BackColor = 'Black'
    $form.Add_Paint({
        param($sender, $e)
        $w = $sender.ClientSize.Width
        $h = $sender.ClientSize.Height
        foreach ($row in $PatternRows) {
            $n = $row.Colours.Count
            for ($i = 0; $i -lt $n; $i++) {
                $c = $row.Colours[$i]
                $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($c[0], $c[1], $c[2]))
                $e.Graphics.FillRectangle($brush, [int]($i * $w / $n), [int]($row.Top * $h), [int]($w / $n) + 1, [int]($row.Height * $h) + 1)
                $brush.Dispose()
            }
        }
    })
    $form.Show()
    return $form
}

function Show-Clock($bounds) {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'AirFeed clock'
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point ($bounds.X + 40), ($bounds.Y + 40)
    $form.Size = New-Object System.Drawing.Size 900, 320
    $form.TopMost = $true
    $form.BackColor = 'Black'
    $label = New-Object System.Windows.Forms.Label
    $label.Dock = 'Fill'
    $label.TextAlign = 'MiddleCenter'
    $label.ForeColor = 'White'
    $label.Font = New-Object System.Drawing.Font 'Consolas', 110, ([System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($label)
    $form.Show()
    $script:ClockLabel = $label
    return $form
}

function Invoke-Test {
    Write-Host "`n== Guided test =="
    if (-not (Test-Ffmpeg)) { Write-Host 'Run setup first.' -ForegroundColor Red; return }
    New-Item -ItemType Directory -Force $Captures | Out-Null
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    try {
        Add-Type -AssemblyName System.Speech
        $script:Voice = New-Object System.Speech.Synthesis.SpeechSynthesizer
    } catch { $script:Voice = $null }

    $screens = [System.Windows.Forms.Screen]::AllScreens
    $main = $screens | Where-Object { $_.Primary } | Select-Object -First 1
    $atem = $screens | Where-Object { -not $_.Primary } | Select-Object -First 1
    if (-not $atem) {
        Write-Host 'Only one display found. Using it, but the ATEM output should be a second display (Extend).' -ForegroundColor Yellow
        $atem = $main
    }
    Write-Host ("ATEM display: {0}  {1} x {2}" -f $atem.DeviceName, $atem.Bounds.Width, $atem.Bounds.Height)

    $script:Stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $file     = Join-Path $Captures "capture-$($script:Stamp).ts"
    $report   = Join-Path $Captures "report-$($script:Stamp).txt"
    $relayLog = Join-Path $Captures "relay-$($script:Stamp).log"
    $playLog  = Join-Path $Captures "player-$($script:Stamp).log"
    $script:Watch = [Diagnostics.Stopwatch]::StartNew()
    $script:ClockLabel = $null
    $total = $PatternSeconds + $ClockSeconds + $PositionSeconds * $Positions.Count + $ReturnSeconds
    Write-Host ("The test runs about {0:n0} minutes once the iPhone connects." -f ($total / 60))

    if (-not $Quick) { Read-Host 'Start recording on the ATEM, then press Enter' | Out-Null }

    # 1. Test pattern on the ATEM output
    Say 'Test pattern.'
    $pattern = Show-Pattern $atem.Bounds
    Wait-Phase $PatternSeconds $null | Out-Null
    $pattern.Close()

    # 2. Receive the iPhone: one SRT listener, saved to disk and passed on to the player
    $player = Start-Process ffplay -PassThru -NoNewWindow -RedirectStandardError $playLog -ArgumentList (
        "-hide_banner -loglevel warning -an -sync ext -fflags nobuffer -flags low_delay -framedrop " +
        "-probesize $Probe -analyzeduration 0 -fs -left $($atem.Bounds.X + 100) -top $($atem.Bounds.Y + 100) " +
        "-window_title AirFeed `"$LocalUrl`"")
    $relay = Start-Process ffmpeg -PassThru -NoNewWindow -RedirectStandardError $relayLog -ArgumentList (
        "-hide_banner -loglevel warning -nostdin -fflags nobuffer -i `"$SrtUrl`" " +
        "-map 0:v -c copy -flush_packets 1 -f mpegts `"$file`" " +
        "-map 0:v -c copy -flush_packets 1 -f mpegts `"${LocalUrl}?pkt_size=1316`"")
    Say 'Start the stream on the iPhone now.'
    while ((Get-Size $file) -eq 0) {
        if ($relay.HasExited -or $script:Watch.Elapsed.TotalSeconds -gt 300) {
            Write-Host "No stream arrived. See $relayLog" -ForegroundColor Red
            if (-not $player.HasExited) { $player.Kill() }
            if (-not $relay.HasExited) { $relay.Kill() }
            return
        }
        Wait-Phase 0.5 $null | Out-Null
    }
    $connected = $script:Watch.Elapsed.TotalSeconds
    $phases = @()

    # 3. Latency: the iPhone films the clock, screenshots catch the clock and its filmed copy
    $clock = Show-Clock $main.Bounds
    Say 'Point the iPhone at the clock on the laptop and hold it still.'
    $r = Wait-Phase $ClockSeconds $file @(($ClockSeconds * 0.5), ($ClockSeconds * 0.7), ($ClockSeconds * 0.9))
    $phases += [pscustomobject]@{ Name = 'Clock'; Start = 0; Seconds = $ClockSeconds; Stall = $r.Stall; Bytes = $r.Bytes }
    $clock.Close()
    $script:ClockLabel = $null

    # 4. Walk test
    for ($i = 0; $i -lt $Positions.Count; $i++) {
        $at = $script:Watch.Elapsed.TotalSeconds - $connected
        Say ("Walk to position {0}: {1}. Keep filming." -f ($i + 1), $Positions[$i])
        $r = Wait-Phase $PositionSeconds $file
        $phases += [pscustomobject]@{ Name = "Position $($i + 1)"; Start = $at; Seconds = $PositionSeconds; Stall = $r.Stall; Bytes = $r.Bytes }
    }
    $at = $script:Watch.Elapsed.TotalSeconds - $connected
    Say 'Come back to the laptop.'
    $r = Wait-Phase $ReturnSeconds $file
    $phases += [pscustomobject]@{ Name = 'Return'; Start = $at; Seconds = $ReturnSeconds; Stall = $r.Stall; Bytes = $r.Bytes }
    Say 'Test finished. Stop the stream on the iPhone and stop the ATEM recording.'

    $playerDied = $player.HasExited
    if (-not $player.HasExited) { $player.Kill() }
    if (-not $relay.HasExited) { $relay.Kill() }
    $relay.WaitForExit(5000) | Out-Null

    # 5. Report
    $out = @("AirFeed guided test $($script:Stamp)", "SRT receive buffer: $LatencyMs ms", '', 'Streams:')
    # MPEG-TS lists each stream twice (once under its programme), hence -Unique.
    $out += & ffprobe -v error -show_entries 'stream=index,codec_type,codec_name,profile,width,height,pix_fmt,color_range,avg_frame_rate,has_b_frames' -of 'compact=p=0' $file |
        Select-Object -Unique | ForEach-Object { "  $_" }

    $packets = @(& ffprobe -v error -select_streams v:0 -show_entries 'packet=pts_time,flags' -of 'csv=p=0' $file)
    $times = @($packets | ForEach-Object { [double]($_ -split ',')[0] } | Sort-Object)
    $keys  = @($packets | Where-Object { $_ -match ',K' } | ForEach-Object { [double]($_ -split ',')[0] })
    if ($keys.Count -gt 1) {
        $gaps = for ($i = 1; $i -lt [math]::Min($keys.Count, 9); $i++) { [math]::Round($keys[$i] - $keys[$i - 1], 2) }
        $out += "Keyframe spacing in seconds: $($gaps -join ' ')"
    }
    if ($times.Count -gt 10) {
        $deltas = for ($i = 1; $i -lt $times.Count; $i++) { $times[$i] - $times[$i - 1] }
        $frame = ($deltas | Sort-Object)[[int]($deltas.Count / 2)]
        $out += ("Frames received: {0}, frame interval {1:n1} ms" -f $times.Count, ($frame * 1000))
        $lost = 0
        $holes = @()
        for ($i = 1; $i -lt $times.Count; $i++) {
            $d = $times[$i] - $times[$i - 1]
            if ($d -gt $frame * 1.5) {
                $lost += [math]::Round($d / $frame) - 1
                $holes += ("{0:n0}s ({1:n0} ms)" -f ($times[$i - 1] - $times[0]), ($d * 1000))
            }
        }
        $out += "Frames lost for good: $lost in $($holes.Count) holes"
        if ($holes) { $out += "  holes at, seconds into the stream: $(($holes | Select-Object -First 20) -join ', ')" }
    }

    $out += @('', 'Phases (start is seconds into the stream; a stall is the longest time no video arrived):')
    foreach ($p in $phases) {
        $out += ("  {0}: start {1:n0} s, longest stall {2:n2} s, {3:n2} Mbit/s" -f $p.Name, $p.Start, $p.Stall, ($p.Bytes * 8 / $p.Seconds / 1e6))
    }
    $complaints = @(Get-Content $playLog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'error|corrupt|conceal|missing|invalid' }).Count
    $out += @('', "Player complaints (lines in the log about damaged video): $complaints")
    if ($playerDied) { $out += 'The player window closed before the end of the test.' }
    $out | Set-Content $report
    Write-Host ''
    $out | ForEach-Object { Write-Host $_ }
    Write-Host @"

Send back for analysis, all from $Captures :
  report-$($script:Stamp).txt, the three latency-$($script:Stamp)-*.png screenshots,
  and the ATEM recording. Keep capture-$($script:Stamp).ts in case it is needed.
"@
}

function Invoke-Step($name) {
    switch ($name) {
        { $_ -in '1', 'setup' } { Invoke-Setup; break }
        { $_ -in '2', 'test' }  { Invoke-Test;  break }
        default { Write-Host "Unknown choice: $name" }
    }
}

if ($Run) { Invoke-Step $Run; exit }

while ($true) {
    Write-Host @"

AirFeed test rig. Test use only, not for a live programme.
  1  Setup (once): ffmpeg, firewall port, iPhone config file
  2  Guided test, about five minutes
  q  Quit
"@
    $choice = Read-Host 'Choose'
    if ($choice -eq 'q') { break }
    Invoke-Step $choice
}

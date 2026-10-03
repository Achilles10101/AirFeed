# AirFeed test rig for the Windows laptop: one setup step and one guided test that covers
# every hardware experiment.
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
# Video bitrates written into the iPhone config, one per quality the app offers. They differ
# from the app's own defaults, so the bitrate in the report shows whether the app used the file.
$Bitrates  = [ordered]@{ High = 8000000; Medium = 5000000; Low = 2500000 }
$Probe     = 32768     # bytes ffplay reads before it starts. If the video window never opens, try 1000000.
$PatternSeconds = 15
$ClockSeconds   = 25
$WalkSeconds    = 0     # length of the walk; 0 = until Enter is pressed
$ConnectSeconds = 600   # how long to wait for the iPhone before giving up
$StallSeconds   = 0.5   # no video arriving for this long counts as a stall
if ($Quick) { $PatternSeconds = $ClockSeconds = $WalkSeconds = 3; $ConnectSeconds = 60 }

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

    # Format from Blackmagic's "Streaming XML File Format" (January 2026), which is written for
    # ATEMs and cameras, not the phone app. The app offers only the qualities Streaming High,
    # Medium and Low, so the profiles carry those names. fps 30 covers every rate up to 30.
    $profiles = foreach ($q in $Bitrates.Keys) {
        $configs = foreach ($fps in 30, 60) {
@"
                <config resolution="1080p" fps="$fps" codec="H264">
                    <bitrate>$($Bitrates[$q])</bitrate>
                    <audio-bitrate>128000</audio-bitrate>
                    <keyframe-interval>2</keyframe-interval>
                </config>
"@
        }
@"
            <profile>
                <name>Streaming $q</name>
                <low-latency/>
$($configs -join "`n")
            </profile>
"@
    }
    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<streaming>
    <service>
        <name>AirFeed Windows</name>
        <key>airfeed</key>
        <servers>
            <server>
                <name>Laptop</name>
                <url>srt://${ip}:${Port}</url>
            </server>
        </servers>
        <profiles default="Streaming High">
$($profiles -join "`n")
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
  2. In Blackmagic Camera (3.2 or later) import it as a custom streaming service. If the app
     refuses this file, keep the service imported earlier and say what the app reported.
  3. Choose service "AirFeed Windows", quality "Streaming High".
  4. Recording settings in the app: 1080p, frame rate equal to the ATEM's video standard,
     codec H.264, colour space Rec.709. Not 4K, Apple Log or HDR.
  5. Do not start streaming yet. Nothing listens until the guided test asks for the stream,
     so an earlier start fails.
  6. Connect the laptop's HDMI output to an ATEM input and put that input on programme.
     In Windows display settings choose Extend, 1920 x 1080, scale 100%, refresh rate equal
     to the ATEM's video standard, HDR and Night light off.
"@
}

function Say($text) { Write-Host "`n>>> $text" -ForegroundColor Cyan }

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

# Bytes captured so far, over every capture file of this test.
function Get-Received {
    $n = 0
    foreach ($f in $script:Parts) { $n += Get-Size $f }
    return $n
}

# One SRT listener that saves the stream to disk and passes it on to the player. ffmpeg exits
# when the iPhone's connection breaks, so each call starts a new capture file, unless the last
# one is still empty.
function Start-Relay {
    if (-not $script:Parts -or (Get-Size $script:Parts[-1]) -gt 0) {
        $script:Parts += Join-Path $Captures ("capture-{0}-{1}.ts" -f $script:Stamp, ($script:Parts.Count + 1))
    }
    $file = $script:Parts[-1]
    $script:RelayAt = $script:Watch.Elapsed.TotalSeconds
    $script:Relay = Start-Process ffmpeg -PassThru -NoNewWindow -RedirectStandardError "$file.log" -ArgumentList (
        "-hide_banner -loglevel warning -nostdin -y -fflags nobuffer -i `"$SrtUrl`" " +
        "-map 0:v -c copy -flush_packets 1 -f mpegts `"$file`" " +
        "-map 0:v -c copy -flush_packets 1 -f mpegts `"${LocalUrl}?pkt_size=1316`"")
}

function Add-Stall($seconds, $note) {
    if ($seconds -ge $StallSeconds) {
        $script:Stalls += ("{0:HH:mm:ss}  {1:n1} s{2}" -f (Get-Date).AddSeconds(-$seconds), $seconds, $note)
    }
}

# Waits while keeping the windows alive and the clock running. Once the listener is up it
# also starts it again after a broken connection and notes every stall, with its time of day.
# $seconds 0 waits for Enter. Returns the bytes received meanwhile.
function Wait-Phase($seconds, $shots) {
    $start = $nextSample = $script:Watch.Elapsed.TotalSeconds
    $size0 = Get-Received
    $shots = @($shots)
    while ($true) {
        $now = $script:Watch.Elapsed.TotalSeconds
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:ClockLabel) { $script:ClockLabel.Text = '{0:00.000}' -f ($now % 100) }
        if ($script:Relay -and $now -ge $nextSample) {
            $nextSample = $now + 0.25
            if ($script:Relay.HasExited -and $now -ge $script:RelayAt + 2) {
                if ($script:LastSize) { $script:Drops++ }
                Start-Relay
            }
            $size = Get-Received
            if ($size -gt $script:LastSize) {
                if ($script:LastSize) { Add-Stall ($now - $script:LastGrow) }
                $script:LastSize = $size
                $script:LastGrow = $now
            }
        }
        if ($shots -and $now -ge $start + $shots[0]) {
            Save-Screenshot (Join-Path $Captures ("latency-{0}-{1}.png" -f $script:Stamp, (++$script:ShotNo)))
            $shots = @($shots | Select-Object -Skip 1)
        }
        if ($seconds) { if ($now -ge $start + $seconds) { break } }
        elseif ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Enter') { break }
        Start-Sleep -Milliseconds 10
    }
    return (Get-Received) - $size0
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

    # A run that was closed half way leaves its ffmpeg holding the port, and the next stream
    # would go to that one.
    Get-CimInstance Win32_Process -Filter "Name = 'ffmpeg.exe' OR Name = 'ffplay.exe'" |
        Where-Object { $_.CommandLine -match ":$Port\?|:$($Port + 1)\b" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    $screens = [System.Windows.Forms.Screen]::AllScreens
    $main = $screens | Where-Object { $_.Primary } | Select-Object -First 1
    $atem = $screens | Where-Object { -not $_.Primary } | Select-Object -First 1
    if (-not $atem) {
        Write-Host 'Only one display found. Using it, but the ATEM output should be a second display (Extend).' -ForegroundColor Yellow
        $atem = $main
    }
    Write-Host ("ATEM display: {0}  {1} x {2}" -f $atem.DeviceName, $atem.Bounds.Width, $atem.Bounds.Height)

    $script:Stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $report  = Join-Path $Captures "report-$($script:Stamp).txt"
    $playLog = Join-Path $Captures "player-$($script:Stamp).log"
    $script:Watch = [Diagnostics.Stopwatch]::StartNew()
    $script:ClockLabel = $script:Relay = $player = $null
    $script:Parts = @()
    $script:Stalls = @()
    $script:Drops = $script:LastSize = $script:LastGrow = $script:ShotNo = 0

    if (-not $Quick) { Read-Host 'Start recording on the ATEM, then press Enter' | Out-Null }

    try {
        # 1. Test pattern on the ATEM output
        Say "Test pattern on the ATEM output for $PatternSeconds seconds."
        $pattern = Show-Pattern $atem.Bounds
        Wait-Phase $PatternSeconds | Out-Null
        $pattern.Close()

        # 2. Receive the iPhone
        $player = Start-Process ffplay -PassThru -NoNewWindow -RedirectStandardError $playLog -ArgumentList (
            "-hide_banner -loglevel warning -an -sync ext -fflags nobuffer -flags low_delay -framedrop " +
            "-probesize $Probe -analyzeduration 0 -fs -left $($atem.Bounds.X + 100) -top $($atem.Bounds.Y + 100) " +
            "-window_title AirFeed `"$LocalUrl`"")
        Start-Relay
        $deadline = $script:Watch.Elapsed.TotalSeconds + $ConnectSeconds
        $lan = @(Get-LanAddress)
        Say 'Start the stream on the iPhone now.'
        Write-Host ('Listening on ' + (($lan | ForEach-Object { "srt://$($_.Address):$Port" }) -join ' and '))
        if ((Test-Path $Config) -and -not ($lan | Where-Object { (Get-Content $Config -Raw) -match "srt://$([regex]::Escape($_.Address)):" })) {
            Write-Host 'The iPhone config file points at another address. Run setup again and import the new file.' -ForegroundColor Red
        }
        Write-Host @"
If Blackmagic Camera cannot connect:
  - iPhone Settings > Privacy & Security > Local Network: Blackmagic Camera must be switched on.
  - The iPhone must be on this network's WiFi, not a guest network and not mobile data.
  - The server address the app shows must be the address above.
  - If Windows asked whether to allow ffmpeg, the answer must have been Allow.
Waiting up to $([int]($ConnectSeconds / 60)) minutes. Ctrl-C stops the test.
"@
        while ((Get-Received) -eq 0) {
            if ($script:Watch.Elapsed.TotalSeconds -gt $deadline) {
                Write-Host "No stream arrived. Note what the app reported, and see $($script:Parts[-1]).log" -ForegroundColor Red
                return
            }
            Wait-Phase 0.5 | Out-Null
        }
        Write-Host 'The iPhone is connected.' -ForegroundColor Green

        # 3. Latency: the iPhone films the clock, screenshots catch the clock and its filmed copy
        $clock = Show-Clock $main.Bounds
        Say "Point the iPhone at the clock on the laptop and hold it still for $ClockSeconds seconds."
        $clockBytes = Wait-Phase $ClockSeconds @(($ClockSeconds * 0.5), ($ClockSeconds * 0.7), ($ClockSeconds * 0.9))
        $clock.Close()
        $script:ClockLabel = $null

        # 4. Free walk
        Say 'Walk around with the iPhone and keep filming.'
        Write-Host 'Every stall is logged with the time of day, so note the time on the phone in spots you care about.'
        if (-not $WalkSeconds) {
            Write-Host 'Back at the laptop: press Enter here first, then stop the stream on the iPhone.'
            while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
        }
        $walkStart = $script:Watch.Elapsed.TotalSeconds
        $walkBytes = Wait-Phase $WalkSeconds
        $walkTime = $script:Watch.Elapsed.TotalSeconds - $walkStart
        Add-Stall ($script:Watch.Elapsed.TotalSeconds - $script:LastGrow) ', and still no video when the test ended'
        Say 'Test finished. Stop the stream on the iPhone and stop the ATEM recording.'
        $playerDied = $player.HasExited
    } finally {
        foreach ($proc in $player, $script:Relay) { if ($proc -and -not $proc.HasExited) { $proc.Kill() } }
    }
    $script:Relay.WaitForExit(5000) | Out-Null

    # 5. Report
    $parts = @($script:Parts | Where-Object { (Get-Size $_) -gt 0 })
    $out = @("AirFeed guided test $($script:Stamp)", "SRT receive buffer: $LatencyMs ms", '', 'Streams:')
    # MPEG-TS lists each stream twice (once under its programme), hence -Unique.
    $out += & ffprobe -v error -show_entries 'stream=index,codec_type,codec_name,profile,width,height,pix_fmt,color_range,avg_frame_rate,has_b_frames' -of 'compact=p=0' $parts[0] |
        Select-Object -Unique | ForEach-Object { "  $_" }

    for ($p = 0; $p -lt $parts.Count; $p++) {
        $packets = @(& ffprobe -v error -select_streams v:0 -show_entries 'packet=pts_time,flags' -of 'csv=p=0' $parts[$p])
        $times = @($packets | ForEach-Object { [double]($_ -split ',')[0] } | Sort-Object)
        $keys  = @($packets | Where-Object { $_ -match ',K' } | ForEach-Object { [double]($_ -split ',')[0] })
        if ($p -eq 0 -and $keys.Count -gt 1) {
            $gaps = for ($i = 1; $i -lt [math]::Min($keys.Count, 9); $i++) { [math]::Round($keys[$i] - $keys[$i - 1], 2) }
            $out += "Keyframe spacing in seconds: $($gaps -join ' ')"
        }
        if ($times.Count -le 10) { continue }
        $deltas = for ($i = 1; $i -lt $times.Count; $i++) { $times[$i] - $times[$i - 1] }
        $frame = ($deltas | Sort-Object)[[int]($deltas.Count / 2)]
        $lost = 0
        $holes = @()
        for ($i = 1; $i -lt $times.Count; $i++) {
            $d = $times[$i] - $times[$i - 1]
            if ($d -gt $frame * 1.5) {
                $lost += [math]::Round($d / $frame) - 1
                $holes += ("{0:n0}s ({1:n0} ms)" -f ($times[$i - 1] - $times[0]), ($d * 1000))
            }
        }
        $out += ("Capture file {0}: {1} frames, frame interval {2:n1} ms. Frames lost for good: {3} in {4} holes" -f ($p + 1), $times.Count, ($frame * 1000), $lost, $holes.Count)
        if ($holes) { $out += "  holes at, seconds into this file: $(($holes | Select-Object -First 20) -join ', ')" }
    }

    $out += ''
    $out += ("Clock: {0:n0} s, {1:n2} Mbit/s" -f $ClockSeconds, ($clockBytes * 8 / $ClockSeconds / 1e6))
    $out += ("Walk: {0:n0} s, {1:n2} Mbit/s" -f $walkTime, ($walkBytes * 8 / $walkTime / 1e6))
    $out += "The iPhone config asks for $(($Bitrates.Values | ForEach-Object { $_ / 1e6 }) -join ' / ') Mbit/s as $($Bitrates.Keys -join ' / ')."
    $out += "Connection broken and listened for again: $($script:Drops) times"
    $out += "Stalls (no video arriving for $StallSeconds s or more), start by this laptop's clock:"
    if ($script:Stalls) { $out += $script:Stalls | ForEach-Object { "  $_" } } else { $out += '  none' }
    $complaints = @(Get-Content $playLog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'error|corrupt|conceal|missing|invalid' }).Count
    $out += @('', "Player complaints (lines in the log about damaged video): $complaints")
    if ($playerDied) { $out += 'The player window closed before the end of the test.' }
    $out | Set-Content $report
    Write-Host ''
    $out | ForEach-Object { Write-Host $_ }
    Write-Host @"

Send back for analysis, all from $Captures :
  report-$($script:Stamp).txt, the three latency-$($script:Stamp)-*.png screenshots,
  and the ATEM recording. Keep the capture-$($script:Stamp)-*.ts files in case they are needed.
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
  2  Guided test: pattern, latency clock, then a free walk
  q  Quit
"@
    $choice = Read-Host 'Choose'
    if ($choice -eq 'q') { break }
    Invoke-Step $choice
}

# AirFeed

iPhone as a wireless camera into an ATEM Mini Pro ISO: iPhone over WiFi (SRT) to a Windows laptop, laptop over HDMI to the ATEM. Software only.

**Status: experiments.** There is no product yet. The steps below run the experiments that decide the design. Decisions and findings are in `CLAUDE.md`.

What is verified so far, all on the Mac with a synthetic stream: the capture script receives SRT, shows it and saves it; the safety gate idea works (see `CLAUDE.md`). Nothing has been tested with a real iPhone, the Windows laptop or the ATEM.

## Mac (done)

Installed: Homebrew `ffmpeg` (no SRT support in this build) and `srt` (adds `srt-live-transmit`). Nothing else is needed for the experiments.

## Mac alternative: what the Blackmagic Camera app sends, and how late

Same questions as the Windows test, answered on the Mac, with SRT loss statistics the Windows rig cannot give. Needs the iPhone and this Mac on the same WiFi. About 15 minutes.

1. On the Mac, in this folder: `experiments/capture.sh`. It prints the address it listens on. If that is not `192.168.0.207:9000`, edit the `<url>` in `experiments/airfeed.xml` first.
2. AirDrop `experiments/airfeed.xml` to the iPhone and save it to Files.
3. In Blackmagic Camera (3.2 or later), open the settings, find the streaming section and import the file as a custom service. The exact menu names are unverified; they come from a blog.
4. Choose service "AirFeed Mac", quality "Streaming High". Use the recording settings listed in the Windows section below. Start streaming.
5. A window titled AirFeed opens on the Mac with the camera picture.
6. Open `experiments/clock.html` in a browser on the Mac. Put it beside the AirFeed window and point the iPhone at the clock so the AirFeed window shows the filmed clock.
7. Take three screenshots a few seconds apart (Cmd+Shift+3).
8. Let it run for a minute, walk around the room with the phone, then stop the stream on the phone and press Ctrl-C in the terminal.
Then tell Claude: iPhone model, app version, anything the app asked for or complained about (stream key, errors), where the screenshots are, the ATEM's video standard, and how the microphones reach the ATEM.

Captures land in `experiments/captures/` (not committed).

## Windows laptop: all hardware tests in one guided run

`windows/airfeed.ps1` is a test rig, not the production receiver. It has no safety gate, so do not put it on a live programme.

### Setup, once (about 10 minutes)

1. Download https://github.com/Achilles10101/AirFeed/archive/refs/heads/main.zip on the laptop and unzip it.
2. Connect the laptop to the router by Ethernet.
3. Double-click `windows\airfeed.cmd` and choose 1. It installs ffmpeg with winget if needed, opens UDP port 9000 to your local network (Windows asks for permission), and writes `windows\airfeed-windows.xml` with the laptop's address.
4. Get that XML onto the iPhone (email, iCloud Drive or OneDrive) and save it in Files.
5. In Blackmagic Camera (3.2 or later) import the file as a custom streaming service. Choose service "AirFeed Windows", quality "Streaming High". The app offers only Streaming High, Medium and Low; the file sets them to 8, 5 and 2.5 Mbit/s.
6. Recording settings in the app: 1080p, frame rate equal to the ATEM's video standard, codec H.264, colour space Rec.709. Not 4K, Apple Log or HDR. These are reasoned, not tested: the report shows what the app really sent.
7. Do not start streaming yet. Nothing listens until the guided test asks for the stream, so an earlier start fails.
8. Connect the laptop's HDMI output to an ATEM input and put that input on programme. In Windows display settings choose Extend, 1920 x 1080, scale 100%, refresh rate equal to the ATEM's video standard, HDR and Night light off.

### Guided test

Choose 2 in the menu. All prompts are on the laptop screen; there is no sound.

| Time | What happens | What you do |
|---|---|---|
| start | asks for the ATEM recording | start recording on the ATEM, press Enter |
| 15 s | test pattern on the ATEM output | nothing |
| until connected, at most 10 min | waits for the iPhone and shows the address it listens on | start the stream in Blackmagic Camera |
| 25 s | clock on the laptop screen, three automatic screenshots | point the iPhone at the clock |
| as long as you like | free walk | walk around filming, then press Enter on the laptop and stop the stream and the ATEM recording |

It then prints a report and saves everything in `windows\captures`. Send back `report-*.txt`, the three `latency-*.png` screenshots and the ATEM recording.

What each part answers: the pattern on the ATEM recording gives colour range. The report gives codec, frame rate, keyframe spacing and lost frames. The screenshots give latency (clock minus filmed clock), which includes a small relay inside the laptop, so treat it as an upper bound. The ATEM recording shows what a viewer would have seen.

Dead zones: the report lists every stall (no video arriving for half a second or more) with the time of day it began and how long it lasted, so note the time on the phone in spots you care about. If the connection breaks completely the laptop listens again by itself and counts it; a stall that ends without you touching the phone means the app reconnected on its own.

If the app cannot connect: on the iPhone, Settings, Privacy & Security, Local Network must have Blackmagic Camera switched on; the iPhone must be on the same network's WiFi, not a guest network or mobile data; the server address in the app must be the one the test prints; and if Windows asked whether to allow ffmpeg, the answer must have been Allow.

Phase lengths, port, SRT buffer, bitrates and the stall threshold are knobs at the top of the script. `airfeed.cmd -Run test -Quick` does a dry run with 3 second phases.

Verified by an automated check on a GitHub Windows machine with a synthetic stream: the script parses, setup runs, and the guided test receives SRT and produces its report. Not verified anywhere: the real laptop, the iPhone app accepting the config file, the pattern and video actually appearing on the ATEM display, restarting the listener after a broken connection, and the winget install.

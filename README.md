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
4. Choose service "AirFeed Mac", profile "AirFeed low latency". Set the frame rate to the ATEM's video standard. Start streaming.
5. A window titled AirFeed opens on the Mac with the camera picture.
6. Open `experiments/clock.html` in a browser on the Mac. Put it beside the AirFeed window and point the iPhone at the clock so the AirFeed window shows the filmed clock.
7. Take three screenshots a few seconds apart (Cmd+Shift+3).
8. Let it run for a minute, walk around the room with the phone, then stop the stream on the phone and press Ctrl-C in the terminal.
9. Repeat from step 1 with profile "AirFeed standard".

Then tell Claude: iPhone model, app version, anything the app asked for or complained about (stream key, errors), where the screenshots are, the ATEM's video standard, and how the microphones reach the ATEM.

Captures land in `experiments/captures/` (not committed).

## Windows laptop: all hardware tests in one guided run

`windows/airfeed.ps1` is a test rig, not the production receiver. It has no safety gate, so do not put it on a live programme.

### Setup, once (about 10 minutes)

1. Download https://github.com/Achilles10101/AirFeed/archive/refs/heads/main.zip on the laptop and unzip it.
2. Connect the laptop to the router by Ethernet.
3. Double-click `windows\airfeed.cmd` and choose 1. It installs ffmpeg with winget if needed, opens UDP port 9000 to your local network (Windows asks for permission), and writes `windows\airfeed-windows.xml` with the laptop's address.
4. Get that XML onto the iPhone (email, iCloud Drive or OneDrive) and save it in Files.
5. In Blackmagic Camera (3.2 or later): settings, streaming, import the file as a custom service. The menu names are unverified. Choose service "AirFeed Windows", profile "AirFeed low latency", and set the frame rate to the ATEM's video standard.
6. Connect the laptop's HDMI output to an ATEM input and put that input on programme. In Windows display settings choose Extend, 1920 x 1080, scale 100%, refresh rate equal to the ATEM's video standard, HDR and Night light off.
7. Turn the laptop's volume up. The test speaks its prompts.

### Guided test (about 5 minutes)

Choose 2 in the menu. The laptop then tells you what to do, on screen and out loud:

| Time | What happens | What you do |
|---|---|---|
| start | asks for the ATEM recording | start recording on the ATEM, press Enter |
| 15 s | test pattern on the ATEM output | nothing |
| until connected | waits for the iPhone | start the stream in Blackmagic Camera |
| 25 s | clock on the laptop screen, three automatic screenshots | point the iPhone at the clock |
| 4 x 45 s | walk test | walk to each position when told: near the router, middle of the hall, far end, worst spot |
| 15 s | return | walk back, then stop the stream and the ATEM recording |

It then prints a report and saves everything in `windows\captures`. Send back `report-*.txt`, the three `latency-*.png` screenshots and the ATEM recording.

What each part answers: the pattern on the ATEM recording gives colour range. The report gives codec, frame rate and keyframe spacing, plus stalls and lost frames per position. The screenshots give latency (clock minus filmed clock), which includes a small relay inside the laptop, so treat it as an upper bound. The ATEM recording shows what a viewer would have seen.

Positions, phase lengths, port and SRT buffer are knobs at the top of the script. `airfeed.cmd -Run test -Quick` does a dry run with 3 second phases.

Verified by an automated check on a GitHub Windows machine with a synthetic stream: the script parses, setup runs, and the guided test receives SRT and produces its report. Not verified anywhere: the real laptop, the iPhone app, the pattern and video actually appearing on the ATEM display, the spoken prompts, and the winget install.

# AirFeed

iPhone as a wireless camera into an ATEM Mini Pro ISO: iPhone over WiFi (SRT) to a Windows laptop, laptop over HDMI to the ATEM. Software only.

**Status: experiments.** There is no product yet. The steps below run the experiments that decide the design. Decisions and findings are in `CLAUDE.md`.

What is verified so far, all on the Mac with a synthetic stream: the capture script receives SRT, shows it and saves it; the safety gate idea works (see `CLAUDE.md`). Nothing has been tested with a real iPhone, the Windows laptop or the ATEM.

## Mac (done)

Installed: Homebrew `ffmpeg` (no SRT support in this build) and `srt` (adds `srt-live-transmit`). Nothing else is needed for the experiments.

## Experiments 1 and 2: what the Blackmagic Camera app sends, and how late

Needs the iPhone and this Mac on the same WiFi. About 15 minutes.

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

## Experiment 3: Windows HDMI into the ATEM

Needs the Windows laptop and the ATEM. About 20 minutes. Windows menu names below are from memory and may differ slightly.

1. Copy `experiments/testpattern.html` to the laptop.
2. Connect the laptop's HDMI output to an ATEM input.
3. Windows Settings, System, Display: select the ATEM display, choose "Extend these displays", resolution 1920 x 1080, scale 100%. Under Advanced display set the refresh rate to match the ATEM's video standard. Turn HDR and Night light off.
4. Open `testpattern.html` in Edge or Chrome, drag it to the ATEM display, press F11.
5. Note the Hz figure shown at the bottom of the pattern, and whether the ATEM showed the picture straight away.
6. Put that input on programme and record about 15 seconds on the ATEM.
7. Copy the recording to the Mac and tell Claude where it is.

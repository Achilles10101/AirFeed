AirFeed project brief

This file is the standing context for the AirFeed project. Read it fully at the start of every session. The design, architecture and technology choices are yours to research, propose and justify with me. This file only gives you the goal, the constraints, the environment and the way I want to work.

GOAL

I want to use an iPhone as a wireless camera into a Blackmagic ATEM Mini Pro ISO over WiFi. The camera side should offer Blackmagic Camera level manual control, either by integrating with the Blackmagic Camera app or by something else if you can make the case for it. The video transmission should be efficient, low latency and dependable enough to sit in a live production.

HARD CONSTRAINTS

The ATEM Mini Pro ISO accepts video only on its HDMI inputs and has no network video input, so whatever we build must end as an HDMI signal into the ATEM. I have a Windows laptop with an HDMI port that can act as the receiver and sit between the network and the ATEM, and I am open to other receiver hardware if you find a clearly better option. The ATEM output may go to a live stream at any moment, so glitched, frozen or garbage frames must never reach it.

ENVIRONMENT

Claude Code runs on my MacBook Air with Apple Silicon. The target receiver is a Windows laptop. You cannot test on Windows or on a real iPhone and ATEM, so never claim anything is verified on hardware you have not touched. State clearly in every summary what you verified here and what I still need to test. If a Windows build is needed, propose how to produce it. Any iPhone code must build in Xcode on this Mac.

WHAT I KNOW AND DO NOT KNOW

Reports say Blackmagic Camera for iOS 3.2 can stream SRT to a custom server. Treat that as a lead to verify, not a fact. I do not know what it actually sends, including codec, resolution, frame rate, audio and whether it connects out to a receiver or waits for one. I do not know the real latency or quality achievable over my WiFi, whether the ATEM input exposes audio over HDMI, or how Windows will handle color range over HDMI into the ATEM. Find out what you can by research, and flag what only hardware testing can answer.

PRIORITIES

Reliability first, then low latency, then image quality, then extra features. Features such as tally, remote camera control or on-phone monitoring tools are welcome ideas but should come after the core path works.

HOW I WANT TO WORK

Start by brainstorming and researching, not coding. Lay out the realistic approaches with their tradeoffs, recommend one, and list the riskiest assumptions along with the cheapest way to test each. Wait for my decision before building anything real. Throwaway prototypes to answer a specific question are fine. Once we have chosen a direction, work in small verifiable steps, commit often, keep dependencies few, and check real documentation or run the thing instead of recalling flags and APIs from memory. Ask me before any decision that could waste hours if wrong, otherwise keep moving. Keep this file updated with decisions made, assumptions disproven and open questions, and keep a README with exact setup steps for each device.

DECISIONS MADE (2026-10-03)

Software only. No hardware decoders, wireless HDMI kits or docks. The receiver is the Windows laptop on Ethernet to the router, so only the iPhone is on WiFi. No audio travels over the stream; programme audio goes into the ATEM directly. When the feed is lost the receiver holds the last good frame for a short adjustable time, then shows black until a clean keyframe arrives.

Camera candidates in order: Blackmagic Camera app over SRT, then Larix Broadcaster (tunable SRT latency, weaker camera control), then our own iPhone app. Later on 2026-10-03 I asked for the Windows receiver to be started while the hardware tests run: build the base app, then pause and wait for the test results. The camera side is still undecided and nothing is to be built for it until I pick a direction after the latency result.

FINDINGS SO FAR

Latency budget. The ATEM Mini Pro spec sheet gives an audio delay of up to 8 frames, on the two analog mic inputs only. Because audio comes from the ATEM, that is the whole lens to ATEM budget: 320 ms at 1080p25, 267 ms at 1080p30, 160 ms at 1080p50, 133 ms at 1080p60. Beyond that lip sync needs a delay in front of the ATEM.

Blackmagic Camera. The 3.2 release notes confirm streaming to custom SRT servers. Blackmagic publishes the config format as "Streaming XML File Format" (January 2026, documents.blackmagicdesign.com/DeveloperManuals/StreamingXMLFileFormat.pdf), written for ATEMs and cameras and not naming the phone app: each profile has config elements with required resolution ("1080p") and fps attributes and an optional codec ("H264" or "H265"), and a service may carry a key. There is no field for SRT latency. The low-latency flag and keyframe interval come only from an unofficial blog (glyph.sh). Version 3.3 adds ATEM tally and camera control, but only through the ProDock over HDMI, which is hardware and out of scope.

First try on the real iPhone (2026-10-03). The first config file, written from the blog (resolution "HD", no fps, our own profile names), imported without complaint, but the app offered only the qualities Streaming Low, Medium and High, and the stream did not connect to the laptop on the same network. Why it did not connect is not known yet. The config now follows the Blackmagic document, uses those three names and sets 8, 5 and 2.5 Mbit/s, which differ from the app's defaults, so a capture shows whether the app uses the file.

Safety gate, verified on the Mac only with a synthetic 720p50 H.264 stream over real SRT with simulated loss. The gate uses SRT packet sequence numbers to spot packets lost for good, passes only whole frames, and after a loss waits for the next IDR. Every decoded frame was compared by MD5 with the clean original. Without the gate 37 to 50 damaged frames were shown per 30 s run. With the gate, zero in every run. Recovery took up to one keyframe interval (longest gap 440 ms with 1 s keyframes). Known gaps in the prototype: H.264 only, and it ignored sequence number wrap.

SRT recovers outages by delivering late. Seven 300 ms outages cost only three packets; the rest were retransmitted after each outage, so they arrived late but intact. The receiver therefore needs a lateness rule as well as a damage rule, or latency grows after every outage.

This Mac. Homebrew ffmpeg has no SRT support; the small srt package is installed and provides srt-live-transmit. Xcode is not installed, only the Command Line Tools, so no iPhone builds are possible yet. Git has no user name or email configured.

WINDOWS TEST RIG

windows/airfeed.ps1 (started with airfeed.cmd) does setup and one guided test: test pattern, capture, latency clock with automatic screenshots, then a free walk that ends on Enter. No sound; I asked for the spoken cues and fixed positions to be removed. The report lists every stall with its time of day, and the listener starts again by itself after a broken connection. It is a test rig built on ffmpeg and ffplay with no safety gate, not the production receiver. A GitHub Actions job on a Windows runner checks that it parses, that setup runs and that a quick guided test receives a synthetic SRT stream. The first version ran on the real laptop as far as importing its config into the app; no stream has arrived there yet.

RECEIVER

receiver/airfeed.c, one C file on libsrt, libavcodec and SDL3. It does its own small MPEG-TS parsing instead of using libavformat. Reasons: the gate needs to know exactly which TS packets belong to which frame, and as far as Claude recalls FFmpeg's MPEG-TS code (not measured here), libavformat adds a second frame of delay through its parser and without the parser splits frames above 200 KB.

The gate has three lines of defence: a jump in SRT packet sequence numbers (31 bit wrap handled), a jump in the TS continuity counter, and the decoder's own damage flags. After any of them nothing is shown until the next H.264 IDR or HEVC IRAP frame. The lateness rule is a one frame mailbox between the receive thread and the display loop: frames are never queued, so a burst of late frames after an outage cannot add delay. The display loop presents on vsync, holds the last good frame for -hold ms (default 500), then draws black.

Known limits, each marked in the code with a ponytail comment: one frame of delay because a frame is complete only when the next begins (could finish early on a PES length), 8 bit 4:2:0 only, software decoding, no recovery point or intra refresh support, PSI tables longer than one TS packet ignored, SRT messages must hold whole TS packets, one PES must hold one frame. A capture file from the guided test will show whether the Blackmagic app breaks any of these.

receiver/test.sh is the check: a 20 s clip through real SRT with a lossy relay, every shown frame compared by MD5 with the clean original, H.264 and HEVC, clean, 5% random loss and 1.5 s outages. Zero damaged frames in every run. With all three defences switched off in a scratch copy the same check reported 24 damaged frames, so it does detect damage. It passes on this Mac and on a GitHub Windows runner against the Windows build (.github/workflows/receiver.yml, MSYS2 UCRT64), which also publishes the bundle as the artifact airfeed-receiver-windows (84 files, 126 MB). Nothing about the receiver has run on the real laptop, with the iPhone, or into the ATEM.

ASSUMPTIONS DISPROVEN

None yet.

OPEN QUESTIONS

What the Blackmagic Camera app really sends: codec, frame rate, keyframe spacing, whether it calls out or listens, how it reconnects, and above all its latency (experiments 1 and 2 in the README). Which iPhone model. The ATEM's video standard, and whether the mics use the ATEM's 3.5 mm jacks. How Windows HDMI arrives at the ATEM: colour range, refresh rate lock, HDCP (experiment 3). WiFi behaviour where the camera will stand, and whether the laptop runs for hours without interruptions. For the receiver: whether the Blackmagic app's stream fits its assumptions (whole TS packets per SRT packet, one frame per PES, real keyframes, 8 bit), whether software decoding keeps up on the laptop, and how full screen on the second display behaves.

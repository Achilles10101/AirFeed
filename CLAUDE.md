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

Camera candidates in order: Blackmagic Camera app over SRT, then Larix Broadcaster (tunable SRT latency, weaker camera control), then our own iPhone app. Nothing beyond experiments is to be built until I pick a direction after the latency result. The proposed receiver is a small custom one built on the FFmpeg libraries and SDL3 with a safety gate, proposed but not yet approved for production.

FINDINGS SO FAR

Latency budget. The ATEM Mini Pro spec sheet gives an audio delay of up to 8 frames, on the two analog mic inputs only. Because audio comes from the ATEM, that is the whole lens to ATEM budget: 320 ms at 1080p25, 267 ms at 1080p30, 160 ms at 1080p50, 133 ms at 1080p60. Beyond that lip sync needs a delay in front of the ATEM.

Blackmagic Camera. The 3.2 release notes confirm streaming to custom SRT servers. Everything else about the stream comes from one unofficial blog (glyph.sh): services are imported as XML with URL, resolution, bitrate, keyframe interval, a low-latency flag and H.264 or H.265, with no field for frame rate or SRT latency. Version 3.3 adds ATEM tally and camera control, but only through the ProDock over HDMI, which is hardware and out of scope.

Safety gate, verified on the Mac only with a synthetic 720p50 H.264 stream over real SRT with simulated loss. The gate uses SRT packet sequence numbers to spot packets lost for good, passes only whole frames, and after a loss waits for the next IDR. Every decoded frame was compared by MD5 with the clean original. Without the gate 37 to 50 damaged frames were shown per 30 s run. With the gate, zero in every run. Recovery took up to one keyframe interval (longest gap 440 ms with 1 s keyframes). Known gaps in the prototype: H.264 only, and it ignored sequence number wrap.

SRT recovers outages by delivering late. Seven 300 ms outages cost only three packets; the rest were retransmitted after each outage, so they arrived late but intact. The receiver therefore needs a lateness rule as well as a damage rule, or latency grows after every outage.

This Mac. Homebrew ffmpeg has no SRT support; the small srt package is installed and provides srt-live-transmit. Xcode is not installed, only the Command Line Tools, so no iPhone builds are possible yet. Git has no user name or email configured.

ASSUMPTIONS DISPROVEN

None yet.

OPEN QUESTIONS

What the Blackmagic Camera app really sends: codec, frame rate, keyframe spacing, whether it calls out or listens, how it reconnects, and above all its latency (experiments 1 and 2 in the README). Which iPhone model. The ATEM's video standard, and whether the mics use the ATEM's 3.5 mm jacks. How Windows HDMI arrives at the ATEM: colour range, refresh rate lock, HDCP (experiment 3). WiFi behaviour where the camera will stand, and whether the laptop runs for hours without interruptions.

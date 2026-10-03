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

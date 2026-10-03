#!/usr/bin/env python3
"""UDP relay that simulates WiFi loss between an SRT caller and listener. Used by test.sh.

usage: lossy.py <listen_port> <target_port> <random_loss 0..1> <blackout_s> <period_s>
Random loss applies to every packet. A blackout drops everything in both directions
for <blackout_s> out of every <period_s>, starting 2 s in. period 0 disables blackouts.
"""
import random
import select
import socket
import sys
import time

listen_port, target_port = int(sys.argv[1]), int(sys.argv[2])
rand_loss, blackout, period = float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])

a = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
a.bind(("127.0.0.1", listen_port))
b = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
target = ("127.0.0.1", target_port)
caller = t0 = None
random.seed(1)

while True:
    ready, _, _ = select.select([a, b], [], [], 5)
    if not ready:
        if caller:
            break  # stream finished
        continue
    for s in ready:
        try:
            data, addr = s.recvfrom(2048)
        except ConnectionResetError:  # Windows reports a closed peer this way
            continue
        if t0 is None:
            t0 = time.monotonic()
        t = time.monotonic() - t0
        if period and t > 2 and t % period < blackout:
            continue
        if random.random() < rand_loss:
            continue
        if s is a:
            caller = addr
            b.sendto(data, target)
        elif caller:
            a.sendto(data, caller)

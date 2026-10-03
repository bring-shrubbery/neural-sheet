#!/usr/bin/env python3
"""Writes NeuralSheet/Resources/test-take.wav: the audio proof's take (sub-issue B).

Three seconds of 16-bit stereo at 22.05 kHz, kept small: an A3 sine in the left channel and an
E4 in the right, at -12 dBFS, with 10 ms fades so it starts and ends without a click.
"""
import math
import pathlib
import struct
import wave

RATE = 22050
SECONDS = 3
AMPLITUDE = 0.25
FADE = int(0.01 * RATE)

out = pathlib.Path(__file__).resolve().parent.parent / "NeuralSheet" / "Resources" / "test-take.wav"
out.parent.mkdir(parents=True, exist_ok=True)

frames = bytearray()
total = RATE * SECONDS
for i in range(total):
    envelope = min(1.0, i / FADE, (total - 1 - i) / FADE)
    left = AMPLITUDE * envelope * math.sin(2 * math.pi * 220.0 * i / RATE)
    right = AMPLITUDE * envelope * math.sin(2 * math.pi * 329.63 * i / RATE)
    frames += struct.pack("<hh", int(left * 32767), int(right * 32767))

with wave.open(str(out), "wb") as wav:
    wav.setnchannels(2)
    wav.setsampwidth(2)
    wav.setframerate(RATE)
    wav.writeframes(bytes(frames))

print(f"{out} ({out.stat().st_size} bytes)")

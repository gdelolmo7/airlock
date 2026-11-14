#!/usr/bin/env python3
"""Makes the dictation start and stop sounds, and the pairs they were chosen from.

Pure arithmetic, so the sounds are a diff like the icon is: sine partials with
a bell-like decay, 16-bit 44.1 kHz stereo, a 2 ms fade in and a 40 ms fade
out, the loudest 50 ms near -26 dBFS like the rest of Resources/Sounds.

    python3 scripts/make-dictation-sounds.py <folder>            # every pair, to listen to
    python3 scripts/make-dictation-sounds.py --install glass     # one pair into Resources/Sounds
"""
import math, os, struct, sys, wave

RATE = 44100
TARGET_DB = -26.0


def tone(freq, length, decay, partials=((1, 1.0), (2, 0.18), (3, 0.06)), start=0.0, total=None):
    n = int((total or (start + length)) * RATE)
    out = [0.0] * n
    first = int(start * RATE)
    for i in range(first, min(n, first + int(length * RATE))):
        t = (i - first) / RATE
        env = math.exp(-t / decay)
        out[i] = env * sum(a * math.sin(2 * math.pi * freq * k * t) for k, a in partials)
    return out


def mix(*tracks):
    n = max(len(t) for t in tracks)
    return [sum(t[i] for t in tracks if i < len(t)) for i in range(n)]


def finish(samples):
    n = len(samples)
    fade_in, fade_out = int(0.002 * RATE), int(0.040 * RATE)
    for i in range(min(fade_in, n)):
        samples[i] *= i / fade_in
    for i in range(min(fade_out, n)):
        samples[n - 1 - i] *= i / fade_out
    window = int(0.050 * RATE)
    loudest = max(
        math.sqrt(sum(s * s for s in samples[i:i + window]) / window)
        for i in range(0, max(1, n - window), window // 4)
    )
    gain = (10 ** (TARGET_DB / 20)) / loudest
    return [max(-1.0, min(1.0, s * gain)) for s in samples]


def write(path, samples):
    with wave.open(path, "wb") as f:
        f.setnchannels(2)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(b"".join(struct.pack("<hh", int(s * 32767), int(s * 32767)) for s in samples))


def two_notes(low, high, rising):
    a, b = (low, high) if rising else (high, low)
    return mix(tone(a, 0.20, 0.07, total=0.30), tone(b, 0.22, 0.08, start=0.08))


PAIRS = {
    # Two soft glass notes: up to start, down to stop.
    "glass": (two_notes(659.25, 987.77, True), two_notes(659.25, 987.77, False)),
    # One low wooden tap to start, two to stop.
    "wood": (
        tone(392.0, 0.12, 0.025, partials=((1, 1.0), (2.76, 0.35), (5.4, 0.12))),
        mix(tone(392.0, 0.10, 0.022, partials=((1, 1.0), (2.76, 0.35), (5.4, 0.12)), total=0.24),
            tone(311.13, 0.12, 0.025, partials=((1, 1.0), (2.76, 0.35), (5.4, 0.12)), start=0.11)),
    ),
    # A single round note: higher to start, lower to stop.
    "drop": (
        tone(783.99, 0.26, 0.06, partials=((1, 1.0), (2, 0.08))),
        tone(523.25, 0.30, 0.07, partials=((1, 1.0), (2, 0.08))),
    ),
}


def main():
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "--install":
        start, stop = PAIRS[args[1]]
        folder = os.path.join(os.path.dirname(__file__), "..", "Resources", "Sounds")
        write(os.path.join(folder, "AirlockDictationStart.wav"), finish(start))
        write(os.path.join(folder, "AirlockDictationStop.wav"), finish(stop))
        return
    if len(args) != 1:
        sys.exit(__doc__)
    os.makedirs(args[0], exist_ok=True)
    for number, (name, (start, stop)) in enumerate(PAIRS.items(), 1):
        write(os.path.join(args[0], f"{number}-{name}-start.wav"), finish(start))
        write(os.path.join(args[0], f"{number}-{name}-stop.wav"), finish(stop))


if __name__ == "__main__":
    main()

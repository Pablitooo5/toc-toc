"""Fabrique les bruitages de Toc Toc (fichiers .wav), sans aucun fichier externe.
Usage : python3 make_sounds.py <dossier de sortie>"""
import math
import os
import random
import struct
import sys
import wave

SR = 44100
random.seed(7)


def write(path, x, level=0.9):
    peak = max(1e-9, max(abs(v) for v in x))
    g = level / peak
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v * g)) * 32767)) for v in x))


def lowpass(x, fc):
    a = 1 - math.exp(-2 * math.pi * fc / SR)
    y, out = 0.0, []
    for v in x:
        y += a * (v - y)
        out.append(y)
    return out


def highpass(x, fc):
    return [a - b for a, b in zip(x, lowpass(x, fc))]


def noise(n, sparse=False):
    if sparse:
        return [(random.uniform(-1, 1) if random.random() < 0.06 else random.uniform(-0.12, 0.12)) for _ in range(n)]
    return [random.uniform(-1, 1) for _ in range(n)]


def mix(*tracks):
    n = max(len(t) for t in tracks)
    return [sum(t[i] if i < len(t) else 0.0 for t in tracks) for i in range(n)]


def sweep_tone(dur, f_start, f_end, tau_f, tau_a, amp=1.0):
    n, ph, out = int(SR * dur), 0.0, []
    for i in range(n):
        t = i / SR
        f = f_end + (f_start - f_end) * math.exp(-t / tau_f)
        ph += 2 * math.pi * f / SR
        out.append(amp * math.sin(ph) * math.exp(-t / tau_a))
    return out


def decay(x, tau, start=0.0):
    return [v * (math.exp(-((i / SR) - start) / tau) if i / SR >= start else 0.0) for i, v in enumerate(x)]


def knock():
    out = [0.0] * int(SR * 0.24)
    for start in (0.0,):
        s = int(start * SR)
        tone = sweep_tone(0.2, 260, 170, 0.03, 0.035)
        click = decay(lowpass(noise(int(SR * 0.2)), 2200), 0.006)
        for i, v in enumerate(mix(tone, [c * 0.8 for c in click])):
            if s + i < len(out):
                out[s + i] += v
    return out


if __name__ == "__main__":
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)
    write(os.path.join(out_dir, "knock.wav"), knock(), 0.7)

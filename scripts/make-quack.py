"""Generates Resources/sounds/Quack.wav, the notification sound: the same pop + quack as in the
launch film (both synthesized, no samples). Run once; the result is committed."""
import os, wave
import numpy as np

SR = 48000
def tt(d): return np.arange(int(d * SR)) / SR
def sweep(f0, f1, d, curve=1.5):
    t = tt(d); f = f0 + (f1 - f0) * (t / d) ** (1 / curve)
    return np.sin(2 * np.pi * np.cumsum(f) / SR)
def attack(sig, ms):
    n = int(ms * SR / 1000); sig = sig.copy(); sig[:n] *= np.linspace(0, 1, n); return sig
def pop(f):
    return attack(sweep(f * 0.55, f * 1.6, 0.11) * np.exp(-tt(0.11) * 32), 1.5)
def quack():
    d = 0.2; t = tt(d); f0 = np.interp(t, [0, 0.05, d], [300, 345, 250])
    ph = 2 * np.pi * np.cumsum(f0) / SR; out = np.zeros(len(t))
    for k in range(1, 30):
        fk = k * f0
        w = sum(np.exp(-0.5 * ((fk - fm) / bw) ** 2) * a for fm, bw, a in ((950, 260, 1), (1650, 300, 0.8), (2750, 420, 0.45)))
        out += w * np.sin(k * ph) / k ** 0.3
    out *= np.interp(t, [0, 0.012, 0.13, d], [0, 1, 0.75, 0]) * (1 + 0.12 * np.sin(2 * np.pi * 34 * t))
    return out / np.abs(out).max()

out = np.zeros(int(0.3 * SR))
p = pop(900); out[:len(p)] += 0.45 * p
q = quack(); i = int(0.04 * SR); out[i:i + len(q)] += 0.45 * q
out *= 0.32 / np.abs(out).max()   # about 8 dB quieter than the film: notifications sit close to the ear
path = os.path.join(os.path.dirname(__file__), '..', 'Resources', 'sounds', 'Quack.wav')
with wave.open(path, 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((out * 32767).astype('<i2').tobytes())
print(path)

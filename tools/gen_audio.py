"""Gera efeitos sonoros chiptune (estilo SNES) usando apenas a stdlib.

Roda com:  py tools/gen_audio.py
Saída:     assets/audio/*.wav  (mono, 16-bit PCM, 44100 Hz)
"""
import math
import os
import random
import struct
import wave

SR = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "audio")

# ---------------------------------------------------------------- osciladores


def square(t, freq, duty=0.5):
    if freq <= 0:
        return 0.0
    return 1.0 if (t * freq) % 1.0 < duty else -1.0


def triangle(t, freq):
    if freq <= 0:
        return 0.0
    p = (t * freq) % 1.0
    return 4.0 * abs(p - 0.5) - 1.0


def sine(t, freq):
    return math.sin(2.0 * math.pi * freq * t)


def noise(_t, _freq=0):
    return random.uniform(-1.0, 1.0)


# ---------------------------------------------------------------- envelopes


def env_ad(i, n, attack=0.01, release=0.06):
    """Ataque linear + decaimento exponencial (suave nas bordas)."""
    t = i / SR
    total = n / SR
    a = min(1.0, t / attack) if attack > 0 else 1.0
    rem = total - t
    r = min(1.0, rem / release) if release > 0 else 1.0
    return a * r


def env_decay(i, n, k=5.0):
    """Decaimento exponencial puro (percussivo)."""
    return math.exp(-k * (i / n))


# ---------------------------------------------------------------- builder


class Buf:
    def __init__(self):
        self.s = []

    def tone(self, dur, freq, osc=square, vol=0.6, duty=0.5,
             attack=0.005, release=0.04, bend=0.0):
        """Acrescenta um tom. `bend` desloca a frequência ao longo do tom
        (semitons do início ao fim)."""
        n = int(dur * SR)
        for i in range(n):
            t = i / SR
            f = freq * (2.0 ** (bend * (i / n) / 12.0))
            if osc is square:
                v = square(t, f, duty)
            elif osc is triangle:
                v = triangle(t, f)
            elif osc is sine:
                v = sine(t, f)
            else:
                v = osc(t, f)
            v *= env_ad(i, n, attack, release) * vol
            self.s.append(v)

    def perc(self, dur, freq, osc=noise, vol=0.6, k=6.0, bend=0.0):
        n = int(dur * SR)
        for i in range(n):
            t = i / SR
            f = freq * (2.0 ** (bend * (i / n) / 12.0))
            v = osc(t, f) * env_decay(i, n, k) * vol
            self.s.append(v)

    def silence(self, dur):
        self.s.extend([0.0] * int(dur * SR))

    def mix_tail(self, dur, freq, osc=square, vol=0.4, duty=0.5):
        """Sobrepõe um tom nas últimas `dur` amostras (acorde)."""
        n = int(dur * SR)
        start = max(0, len(self.s) - n)
        for i in range(start, len(self.s)):
            t = (i - start) / SR
            self.s[i] += square(t, freq, duty) * env_ad(
                i - start, n, 0.005, 0.04) * vol

    def write(self, name):
        # normaliza picos e aplica fade nas pontas para evitar clicks
        peak = max((abs(x) for x in self.s), default=1.0) or 1.0
        norm = 0.9 / peak if peak > 0.9 else 1.0
        fade = int(0.003 * SR)
        out = bytearray()
        n = len(self.s)
        for i, x in enumerate(self.s):
            g = 1.0
            if i < fade:
                g = i / fade
            elif i > n - fade:
                g = (n - i) / fade
            v = max(-1.0, min(1.0, x * norm * g))
            out += struct.pack("<h", int(v * 32767))
        path = os.path.join(OUT, name)
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(bytes(out))
        print(f"  {name:14s} {n/SR:5.2f}s")


# ---------------------------------------------------------------- notas

A4 = 440.0


def nt(semis):
    """Frequência a `semis` semitons de A4."""
    return A4 * (2.0 ** (semis / 12.0))


# nomes úteis (semitons relativos a A4=0)
C5, D5, E5, F5, G5, A5, B5 = 3, 5, 7, 8, 10, 12, 14
C6, D6, E6, G6, C7 = 15, 17, 19, 22, 27


# ---------------------------------------------------------------- sons


def gen_jump():
    b = Buf()
    b.tone(0.11, nt(C5), vol=0.5, duty=0.5, bend=14, attack=0.002,
           release=0.05)
    b.write("jump.wav")


def gen_coin():
    b = Buf()
    b.tone(0.06, nt(B5), vol=0.55, duty=0.5, release=0.02)
    b.tone(0.34, nt(E6), vol=0.55, duty=0.5, release=0.20)
    b.write("coin.wav")


def gen_stomp():
    b = Buf()
    b.perc(0.05, 220, osc=noise, vol=0.6, k=8)
    b.tone(0.13, nt(C5), osc=square, vol=0.5, duty=0.5, bend=-16,
           attack=0.002, release=0.05)
    b.write("stomp.wav")


def gen_brick():
    b = Buf()
    b.perc(0.18, 400, osc=noise, vol=0.7, k=10)
    b.tone(0.10, nt(C5), osc=square, vol=0.35, bend=-10, release=0.06)
    b.write("brick.wav")


def gen_powerup():
    b = Buf()
    seq = [G5, C6, E6, G6, C7]
    for s in seq:
        b.tone(0.08, nt(s), vol=0.5, duty=0.5, attack=0.002, release=0.03)
    b.write("powerup.wav")


def gen_star():
    b = Buf()
    seq = [C6, E6, G6, C7, G6, E6]
    for r in range(2):
        for s in seq:
            b.tone(0.055, nt(s), vol=0.45, duty=0.25, attack=0.002,
                   release=0.02)
    b.write("star.wav")


def gen_hurt():
    b = Buf()
    b.tone(0.30, nt(E5), osc=square, vol=0.5, duty=0.5, bend=-20,
           attack=0.002, release=0.12)
    b.write("hurt.wav")


def gen_death():
    b = Buf()
    # jinglezinho descendente
    b.tone(0.10, nt(B5), vol=0.5, release=0.04)
    b.tone(0.10, nt(F5), vol=0.5, release=0.04)
    b.silence(0.04)
    b.tone(0.10, nt(E5), vol=0.5, release=0.04)
    b.tone(0.10, nt(C5), vol=0.5, release=0.04)
    b.tone(0.30, nt(C5 - 5), vol=0.5, bend=-4, release=0.18)
    b.write("death.wav")


def gen_gameover():
    b = Buf()
    notes = [E5, D5, C5, C5 - 2, C5 - 5]
    for i, s in enumerate(notes):
        d = 0.18 if i < len(notes) - 1 else 0.5
        b.tone(d, nt(s), osc=triangle, vol=0.55, attack=0.004,
               release=0.10 if i < len(notes) - 1 else 0.3)
    b.write("gameover.wav")


def gen_start():
    b = Buf()
    for s in [C5, E5, G5]:
        b.tone(0.07, nt(s), vol=0.5, duty=0.5, release=0.03)
    b.tone(0.22, nt(C6), vol=0.55, duty=0.5, release=0.14)
    b.mix_tail(0.22, nt(E6), vol=0.3)
    b.write("start.wav")


def gen_fever():
    b = Buf()
    for s in [C6, G5, C6, E6]:
        b.tone(0.06, nt(s), vol=0.5, duty=0.25, release=0.02)
    b.write("fever.wav")


def main():
    os.makedirs(OUT, exist_ok=True)
    random.seed(7)
    print("Gerando efeitos sonoros em", os.path.normpath(OUT))
    gen_jump()
    gen_coin()
    gen_stomp()
    gen_brick()
    gen_powerup()
    gen_star()
    gen_hurt()
    gen_death()
    gen_gameover()
    gen_start()
    gen_fever()
    print("OK")


if __name__ == "__main__":
    main()

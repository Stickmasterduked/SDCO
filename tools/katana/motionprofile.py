"""Lumen Rush's dash: the same velocity curve Motion.rush uses in game.

v(u) ~ u^A * (1 - u)^B on u = 0..1: a hard but visible acceleration out of
the launch, a peak about a quarter of the way in, then a long braking glide
that settles the body right in front of the target (no slide after the cut).
"""
A, B = 0.5, 1.4
STEPS = 256


def _v(u):
    return (u ** A) * ((1 - u) ** B)


_CUM = [0.0]
for i in range(STEPS):
    u0, u1 = i / STEPS, (i + 1) / STEPS
    _CUM.append(_CUM[-1] + (_v(u0) + _v(u1)) / 2 / STEPS)
TOTAL = _CUM[-1]


def fraction(u):
    """Share of the distance covered by u (0..1)."""
    if u <= 0:
        return 0.0
    if u >= 1:
        return 1.0
    x = u * STEPS
    i = int(x)
    return (_CUM[i] + (_CUM[i + 1] - _CUM[i]) * (x - i)) / TOTAL


def speed(u, distance, duration):
    if u <= 0 or u >= 1:
        return 0.0
    return distance / duration * _v(u) / TOTAL

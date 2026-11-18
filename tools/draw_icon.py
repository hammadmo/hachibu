#!/usr/bin/env python3
"""Draws the Hachibu icon layers into Icon/AppIcon.icon/Assets.

An enso: one brush stroke around a circle, left open. The stroke starts
with a pool of ink, wavers like a hand-held brush, and ends in dry bristle
streaks (kasure). Gold dust (nashiji, as on lacquerware) drifts across the
gap, so the eye finishes the circle that the brush did not. Plum blossoms
(ume), the first flower of the year and a classic lacquer motif, open among
the dust. Waves (seigaiha, the pattern of calm seas) rise from the bottom
edge in low relief, tone on tone. A hand-stamped seal with the character for
eight sits over the stroke.

Usage: tools/draw_icon.py && tools/make_icon.sh
"""
import math, os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(HERE, "Icon", "AppIcon.icon", "Assets")
CX = CY = 512
R = 272          # centerline radius
T = 104          # brush width at its fullest
END = 0.80       # the stroke covers this much of the circle
GOLD, SEAL, PAPER = "#C9A45C", "#B4322A", "#F4E9D6"
PALE_GOLD, RELIEF = "#E6CB8C", "#4B3A20"


def wobble(u, seed):
    """A small, smooth, repeatable waver between -1 and 1."""
    return (math.sin(u * 23 + seed) * 0.6 + math.sin(u * 57 + seed * 2.3) * 0.3
            + math.sin(u * 131 + seed * 5.1) * 0.1)


def radius(u):
    # A hand never draws a true circle: it drifts, and pulls inward at the end.
    return R * (1 + 0.012 * wobble(u, 1.0) - 0.05 * max(u - 0.45, 0) ** 1.5)


def point(u, offset):
    a = -math.pi / 2 + u * 2 * math.pi
    r = radius(u) + offset
    return CX + r * math.cos(a), CY + r * math.sin(a)


def band(u0, u1, outer, inner, steps=160, hole=False):
    """A closed band between two edges. outer(u) and inner(u) are offsets
    from the centerline. A hole runs the other way round, so it cuts out."""
    us = [u0 + (u1 - u0) * i / steps for i in range(steps + 1)]
    a = [point(u, outer(u)) for u in us]
    b = [point(u, inner(u)) for u in reversed(us)]
    pts = (b + a) if hole else (a + b)
    if hole:
        pts = list(reversed(a)) + list(reversed(b))
    return "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in pts) + "Z"


def blob(u, offset, r, steps=40):
    cx, cy = point(u, offset)
    pts = [(cx + r * (1 + 0.08 * wobble(i / steps, 7)) * math.cos(2 * math.pi * i / steps),
            cy + r * (1 + 0.08 * wobble(i / steps, 7)) * math.sin(2 * math.pi * i / steps))
           for i in range(steps)]
    return "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in pts) + "Z"


def svg(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            f'viewBox="0 0 1024 1024">{body}</svg>\n')


def ring():
    body_end = 0.70

    def width(u):
        # Heavy where the brush lands, even through the middle, thinning late.
        land = 1.12 - 0.12 * min(u / 0.10, 1)
        thin = 1 - 0.28 * max((u - 0.50) / (body_end - 0.50), 0) ** 1.4
        return T / 2 * land * thin

    outer = lambda u: width(u) * (1 + 0.07 * wobble(u, 2.0))
    inner = lambda u: -width(u) * (1 + 0.07 * wobble(u, 4.0))
    parts = [band(0.006, body_end, outer, inner, steps=260)]
    # The pool of ink where the brush first touches down.
    parts.append(blob(0.008, 4, T * 0.60))
    parts.append(blob(0.0, -T * 0.30, T * 0.30))

    # Dry-brush streaks: the bristles separate and run out of ink one by one.
    strands = [(-0.40, 0.752, 0.17), (-0.20, 0.800, 0.20), (0.00, 0.776, 0.16),
               (0.19, 0.792, 0.19), (0.39, 0.740, 0.15)]
    for lane, end, share in strands:
        start = 0.60

        def half(u, end=end, share=share):
            t = (u - start) / (end - start)
            return max(T * share / 2 * (1 - t ** 1.6), 0.8)

        center = lambda u, lane=lane: lane * T * (1 - 0.25 * max((u - 0.6) / 0.2, 0))
        parts.append(band(start, end, lambda u: center(u) + half(u) * (1 + 0.1 * wobble(u, lane * 9)),
                          lambda u: center(u) - half(u), steps=80))

    # Flying white: slivers where the paper shows through the stroke.
    for lane, u0, u1, fat in [(-0.18, 0.40, 0.60, 4.5), (0.22, 0.46, 0.62, 3.5), (0.02, 0.50, 0.60, 3.0)]:
        def half(u, u0=u0, u1=u1, fat=fat):
            t = (u - u0) / (u1 - u0)
            return fat * math.sin(math.pi * min(max(t, 0), 1)) ** 0.7

        parts.append(band(u0, u1, lambda u: lane * T + half(u), lambda u: lane * T - half(u),
                          steps=60, hole=True))
    return svg(f'<path fill="{GOLD}" fill-rule="nonzero" d="{" ".join(parts)}"/>')


def dust():
    # Gold dust across the gap: dense near the brush tip, thinning toward the start.
    specks = []
    for i in range(64):
        k = i / 63
        u = END - 0.01 + (1.0 - END + 0.02) * (k ** 0.85) + 0.012 * wobble(k, 11)
        spread = T * (0.55 + 0.5 * k)
        offset = spread * wobble(k * 3.1, 13 + i) - 0.05 * R * max(u - 0.45, 0) ** 1.5
        size = (9.5 - 6.5 * k) * (0.5 + 0.5 * abs(wobble(k * 5, 17 + i)))
        x, y = point(u, offset)
        specks.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{max(size, 1.8):.1f}"/>')
    return svg(f'<g fill="{GOLD}">{"".join(specks)}</g>')


def ring_band(cx, cy, rho, w, a0, a1):
    """A thin filled arc band (not a stroke) from angle a0 to a1."""
    n = max(int(abs(a1 - a0) * rho / 6), 4)
    angles = [a0 + (a1 - a0) * i / n for i in range(n + 1)]
    out = [(cx + (rho + w / 2) * math.cos(a), cy + (rho + w / 2) * math.sin(a)) for a in angles]
    inn = [(cx + (rho - w / 2) * math.cos(a), cy + (rho - w / 2) * math.sin(a)) for a in reversed(angles)]
    return "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in out + inn) + "Z"


def waves():
    """Seigaiha: rows of overlapping scales, each three concentric arcs.
    Each arc is drawn only where the rows below do not cover it."""
    r, parts = 78, []
    rows = 6
    for row in range(rows):
        cy = 1024 + r * 0.25 - row * r / 2
        shift = r if row % 2 else 0
        # The pattern rises higher on the left, like a shoreline.
        for col in range(-1, 9):
            cx = col * 2 * r + shift
            crest = 1024 - (rows - 0.4) * r / 2 * (1 - 0.55 * max(cx, 0) / 1024)
            if cy < crest:
                continue
            fade = 1 - 0.5 * row / rows
            covers = [(cx - r, cy + r / 2), (cx + r, cy + r / 2), (cx, cy + r)]
            for share, w in [(1.0, 7.0), (0.70, 5.5), (0.40, 4.5)]:
                rho, run = r * share, []
                steps = 90
                for i in range(steps + 1):
                    a = math.pi + math.pi * i / steps          # the upper half
                    x, y = cx + rho * math.cos(a), cy + rho * math.sin(a)
                    seen = all(math.hypot(x - ox, y - oy) >= r - 0.5 for ox, oy in covers)
                    if seen:
                        run.append(a)
                    if (not seen or i == steps) and len(run) > 1:
                        parts.append(ring_band(cx, cy, rho, w * fade, run[0], run[-1]))
                    if not seen:
                        run = []
    return svg(f'<path fill="{RELIEF}" d="{" ".join(parts)}"/>')


def blossom(cx, cy, size, turn, petals=5):
    """An ume blossom: five round petals, a clear heart, and stamens."""
    out = []
    for i in range(petals):
        a = math.radians(turn) + 2 * math.pi * i / 5
        px, py = cx + size * 0.62 * math.cos(a), cy + size * 0.62 * math.sin(a)
        out.append(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="{size * 0.46:.1f}" fill="{PALE_GOLD}"/>')
    if petals == 5:
        out.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{size * 0.36:.1f}" fill="{PALE_GOLD}"/>')
        for i in range(5):
            a = math.radians(turn + 36) + 2 * math.pi * i / 5
            sx, sy = cx + size * 0.30 * math.cos(a), cy + size * 0.30 * math.sin(a)
            out.append(f'<circle cx="{sx:.1f}" cy="{sy:.1f}" r="{size * 0.075:.1f}" fill="{SEAL}"/>')
        out.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{size * 0.10:.1f}" fill="{SEAL}"/>')
    return "".join(out)


def petal(cx, cy, size, turn):
    return (f'<ellipse cx="{cx:.1f}" cy="{cy:.1f}" rx="{size:.1f}" ry="{size * 0.62:.1f}" '
            f'fill="{PALE_GOLD}" transform="rotate({turn} {cx:.1f} {cy:.1f})"/>')


def blossoms():
    # In the gap, where the dust is: one open flower, one half-turned, loose petals.
    x1, y1 = point(0.895, 6)
    x2, y2 = point(0.955, 52)
    art = blossom(x1, y1, 46, -18) + blossom(x2, y2, 27, 12)
    for u, off, size, turn in [(0.845, -46, 11, 30), (0.925, -58, 9, -40), (0.985, -20, 8, 70), (0.865, 66, 8, 10)]:
        x, y = point(u, off)
        art += petal(x, y, size, turn)
    return svg(art)


SEAL_BOX = (630, 628, 184)   # x, y, size
SEAL_TILT = -5               # degrees: stamped by hand, never quite square


def seal():
    x, y, s = SEAL_BOX
    turn = f'rotate({SEAL_TILT} {x + s / 2} {y + s / 2})'
    return svg(f'<rect x="{x}" y="{y}" width="{s}" height="{s}" rx="30" fill="{SEAL}" transform="{turn}"/>')


def eight():
    x, y, s = SEAL_BOX
    ox, oy, k = x + s / 2, y + s / 2, s / 172
    P = lambda pts: " ".join(f"{ox + a * k:.1f} {oy + b * k:.1f}" for a, b in pts)
    left = f'M{P([(-14, -44)])} L{P([(4, -40)])} Q{P([(-2, 14), (-44, 50)])} L{P([(-58, 36)])} Q{P([(-22, 6), (-14, -44)])}Z'
    right = f'M{P([(10, -50)])} L{P([(28, -52)])} Q{P([(34, 10), (62, 36)])} L{P([(48, 52)])} Q{P([(16, 18), (10, -50)])}Z'
    turn = f'rotate({SEAL_TILT} {ox} {oy})'
    return svg(f'<path fill="{PAPER}" d="{left} {right}" transform="{turn}"/>')


if __name__ == "__main__":
    os.makedirs(ASSETS, exist_ok=True)
    for name, art in [("ring.svg", ring()), ("dust.svg", dust()), ("waves.svg", waves()),
                      ("blossoms.svg", blossoms()), ("seal.svg", seal()), ("eight.svg", eight())]:
        with open(os.path.join(ASSETS, name), "w") as f:
            f.write(art)
    print("wrote", ASSETS)

"""CARBON app icon explorations. Renders 1024x1024 PNGs plus a comparison sheet.

Tactura tokens: bg #0A0A0B, text #F4F4F1, muted #8C8C93, line #2A2A2F, accent #FF3B2F.
"""
import math
import sys
from pathlib import Path

import cairosvg
from PIL import Image, ImageDraw, ImageFont

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "out")
FONTS = Path(sys.argv[2] if len(sys.argv) > 2 else "fonts")
OUT.mkdir(parents=True, exist_ok=True)

BG, W, MUTED, LINE, RED = "#0A0A0B", "#F4F4F1", "#8C8C93", "#2A2A2F", "#FF3B2F"
C = 512  # center
ORBIT_R = 330
E_R = 50  # electron radius


def svg(body: str) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
        f'<rect width="1024" height="1024" fill="{BG}"/>{body}</svg>'
    )


def circle(cx, cy, r, fill="none", stroke="none", sw=0):
    return f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{r:.2f}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>'


def polar(r, deg):
    a = math.radians(deg - 90)  # 0 deg = top, clockwise
    return C + r * math.cos(a), C + r * math.sin(a)


def electrons(r_orbit, angles, er, red_index=None, halo=24):
    out = []
    for i, ang in enumerate(angles):
        x, y = polar(r_orbit, ang)
        out.append(circle(x, y, er + halo, fill=BG))  # breaks the orbit line around each electron
        out.append(circle(x, y, er, fill=RED if i == red_index else W))
    return "".join(out)


def dotted_orbit(r, n, dot_r, color=W):
    return "".join(circle(*polar(r, 360 * i / n), dot_r, fill=color) for i in range(n))


def lens(r_outer=150):
    # Camera lens read as a nucleus: barrel ring, glass, inner element ring, glint.
    return (
        circle(C, C, r_outer, fill=W)
        + circle(C, C, r_outer * 0.72, fill=BG)
        + circle(C, C, r_outer * 0.47, stroke=MUTED, sw=12)
        + circle(C - r_outer * 0.25, C - r_outer * 0.25, r_outer * 0.13, fill=W)
    )


def aperture(R=165, blades=6, open_r=70, gap=13, rot=12):
    # Iris: white disk, hexagonal opening, blade seams. Six blades = carbon's atomic number.
    pts = [polar(open_r, rot + 360 * i / blades) for i in range(blades)]
    body = circle(C, C, R, fill=W)
    body += '<polygon points="' + " ".join(f"{x:.2f},{y:.2f}" for x, y in pts) + f'" fill="{BG}"/>'
    for i in range(blades):
        (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % blades]
        dx, dy = x1 - x0, y1 - y0
        n = math.hypot(dx, dy)
        dx, dy = dx / n, dy / n
        # extend from vertex x1 along the edge direction until it meets the outer circle
        px, py = x1 - C, y1 - C
        b = px * dx + py * dy
        t = -b + math.sqrt(b * b - (px * px + py * py - R * R))
        body += (
            f'<line x1="{x1:.2f}" y1="{y1:.2f}" x2="{x1 + dx * t:.2f}" y2="{y1 + dy * t:.2f}" '
            f'stroke="{BG}" stroke-width="{gap}" stroke-linecap="round"/>'
        )
    body += circle(C, C, R, stroke=BG, sw=6)
    return body


VARIANTS = {}

# A · VALENCE: closest to the sketch. One orbit, four valence electrons, lens nucleus, red tally light.
VARIANTS["a-valence"] = svg(
    circle(C, C, ORBIT_R, stroke=W, sw=24)
    + electrons(ORBIT_R, [0, 90, 180, 270], E_R, red_index=0)
    + lens(150)
)

# B · BOHR: the real carbon atom. Inner shell 2 electrons, outer shell 4. Dot-matrix orbits.
VARIANTS["b-bohr"] = svg(
    dotted_orbit(ORBIT_R, 44, 9)
    + dotted_orbit(220, 30, 7, color=MUTED)
    + electrons(220, [45, 225], 36, halo=16)
    + electrons(ORBIT_R, [0, 90, 180, 270], E_R)
    + circle(C, C, 118, fill=W)
    + circle(C, C, 38, fill=RED)
)

# C · APERTURE: nucleus is a 6-blade camera iris (carbon is element 6).
VARIANTS["c-aperture"] = svg(
    circle(C, C, ORBIT_R, stroke=W, sw=22)
    + electrons(ORBIT_R, [0, 90, 180, 270], E_R, red_index=0)
    + aperture()
)

# D · SHUTTER: Nothing-glyph style. Orbit broken into four arcs, red pupil, electrons sit in the gaps.
def arc(r, a0, a1, sw, color=W):
    x0, y0 = polar(r, a0)
    x1, y1 = polar(r, a1)
    large = 1 if (a1 - a0) % 360 > 180 else 0
    return (
        f'<path d="M {x0:.2f} {y0:.2f} A {r} {r} 0 {large} 1 {x1:.2f} {y1:.2f}" '
        f'fill="none" stroke="{color}" stroke-width="{sw}" stroke-linecap="round"/>'
    )


VARIANTS["d-shutter"] = svg(
    "".join(arc(ORBIT_R, a + 22, a + 68, 30) for a in (0, 90, 180, 270))
    + "".join(circle(*polar(ORBIT_R, a), 46, fill=W) for a in (45, 135, 225, 315))
    + circle(C, C, 150, fill=W)
    + circle(C, C, 104, fill=BG)
    + circle(C, C, 46, fill=RED)
)


# Round 2 · C with a red dot-matrix orbit, all-white electrons, aperture nucleus.
ROUND2 = {
    "c2-red-orbit": svg(
        dotted_orbit(ORBIT_R, 44, 9, color=RED)
        + electrons(ORBIT_R, [0, 90, 180, 270], E_R, halo=18)
        + aperture()
    ),
    "c2-red-orbit-bold": svg(
        dotted_orbit(ORBIT_R, 40, 14, color=RED)
        + electrons(ORBIT_R, [0, 90, 180, 270], E_R, halo=20)
        + aperture()
    ),
    "c2-red-orbit-dense": svg(
        dotted_orbit(ORBIT_R, 56, 10, color=RED)
        + electrons(ORBIT_R, [0, 90, 180, 270], E_R, halo=18)
        + aperture()
    ),
}
if "--round2" in sys.argv:
    VARIANTS = dict(ROUND2)


def render(name, s):
    p = OUT / f"{name}.png"
    cairosvg.svg2png(bytestring=s.encode(), write_to=str(p), output_width=1024, output_height=1024)
    (OUT / f"{name}.svg").write_text(s)
    return Image.open(p).convert("RGB")


def ios_mask(img, size):
    # Approximation of the iOS icon shape (continuous corners, about 22.4% radius).
    small = img.resize((size, size), Image.LANCZOS)
    m = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size * 4 - 1, size * 4 - 1], radius=int(size * 4 * 0.2237), fill=255)
    m = m.resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(small, (0, 0), m)
    return out


def sheet(images):
    f_label = ImageFont.truetype(str(FONTS / "space-mono-latin-700-normal.ttf"), 22)
    f_small = ImageFont.truetype(str(FONTS / "space-mono-latin-400-normal.ttf"), 16)
    f_title = ImageFont.truetype(str(FONTS / "doto-latin-700-normal.ttf"), 64)
    col, big = 380, 320
    width = 60 + col * len(images)
    height = 920
    s = Image.new("RGB", (width, height), "#16161A")
    d = ImageDraw.Draw(s)
    d.text((60, 40), "CARBON / ICON STUDY", font=f_title, fill=W)
    d.text((62, 120), "01 · TACTURA TOKENS · 1024 MASTER · SHOWN AT HOME-SCREEN SIZES", font=f_small, fill=MUTED)
    for i, (name, img) in enumerate(images.items()):
        x = 60 + i * col
        d.text((x, 180), name.replace("-", " / ").upper(), font=f_label, fill=W)
        s.paste(ios_mask(img, big), (x, 225), ios_mask(img, big))
        # actual-size previews on a dark and a light wallpaper
        for j, (wall, label) in enumerate((("#3A3F4A", "DARK WALLPAPER"), ("#D9D4C7", "LIGHT WALLPAPER"))):
            y = 580 + j * 160
            d.rectangle([x, y, x + big, y + 130], fill=wall)
            for k, sz in enumerate((60, 40, 29)):
                ic = ios_mask(img, sz)
                s.paste(ic, (x + 20 + k * 100, y + 20 + (60 - sz) // 2), ic)
            d.text((x, y + 136), f"{label} · 60 / 40 / 29 PX", font=f_small, fill=MUTED)
    return s


if __name__ == "__main__" and "--round3" not in sys.argv:
    imgs = {n: render(n, s) for n, s in VARIANTS.items()}
    sheet(imgs).save(OUT / "icon-study.png")
    print("ok", sorted(p.name for p in OUT.iterdir()))


# Round 3 · A (valence) with a white dot-matrix orbit, white electrons, red only in the lens.
def lens3(r_outer=150, ring_color=W, glint_color=RED, glint_scale=0.15):
    return (
        circle(C, C, r_outer, fill=W)
        + circle(C, C, r_outer * 0.72, fill=BG)
        + circle(C, C, r_outer * 0.47, stroke=ring_color, sw=12)
        + circle(C - r_outer * 0.17, C - r_outer * 0.17, r_outer * glint_scale, fill=glint_color)
    )


ROUND3 = {
    "a3-red-ring": svg(
        dotted_orbit(ORBIT_R, 44, 9)
        + electrons(ORBIT_R, [0, 90, 180, 270], E_R, halo=18)
        + lens3(ring_color=RED)
    ),
    "a3-red-dot": svg(
        dotted_orbit(ORBIT_R, 44, 9)
        + electrons(ORBIT_R, [0, 90, 180, 270], E_R, halo=18)
        + lens3(ring_color=W)
    ),
}

if __name__ == "__main__" and "--round3" in sys.argv:
    imgs = {n: render(n, s) for n, s in ROUND3.items()}
    sheet(imgs).save(OUT / "icon-study.png")
    print("round3 ok")

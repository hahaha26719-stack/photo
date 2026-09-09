#!/usr/bin/env python3
"""
Integrate honors from the "Names_organized" sheet of `Parness Hayom names 2026.ods`
into the daily sponsorship slides found in pics.zip (output_days_jpg/YYYY-MM-DD.jpg).

Each template slide has three lines:
    Thank You <donor name>
    for sponsoring <Date>          (already rendered correctly per file)
    in honor of <honor>.

This script replaces the "<honor>" placeholder on the third line with the honor(s)
listed for that calendar day in the Names_organized sheet, matching the template's
serif font (Liberation Serif ~ Times New Roman), navy color, centering and position.

Honors in the sheet are keyed by calendar month + day (recurring annually). Slides run
Sep 2026 -> Jun 2027, so Sep-Dec map to the 2026 rows and Jan-Jun to 2027 rows -- the
month/day match is all that's needed.

Usage:
    # from a directory that contains the .ods and an unzipped pics/output_days_jpg/
    python3 generate_honor_images.py \
        --ods "Parness Hayom names 2026.ods" \
        --src pics/output_days_jpg \
        --out output_with_honors

Requires: pandas, odfpy, Pillow, and a Liberation Serif (or Times) TTF.
Days with no honor in the sheet get a clean "in honor of this day." line.
"""
import os
import glob
import json
import argparse

import pandas as pd
from PIL import Image, ImageDraw, ImageFont
import numpy as np

# ---- template geometry (measured from the 1920x1080 slides) ----
CENTER_X = 960
LINE3_CENTER_Y = 750                 # vertical center of original "in honor of" line
COVER_BOX = (285, 655, 1635, 885)    # central rect repainted to remove old line 3
# Central rect over line 1 ("Thank You <donor name>"), repainted to delete it.
# Side leaf/border art stays outside x<=85 / x>=1792 in this band; logo ends ~y253
# above and line 2 starts ~y546 below, so this band is safe.
TITLE_BOX = (330, 360, 1630, 495)
MAX_TEXT_W = 1360                    # max width for a rendered line
MAX_BLOCK_TOP = 660
MAX_BLOCK_BOTTOM = 880               # stay above the gold olive branch (~y896)
NAVY = (20, 32, 60)
BASE_SIZE = 79                       # body size matching line 2 / line 3
MIN_SIZE = 34

DEFAULT_FONT_CANDIDATES = [
    "/usr/share/fonts/liberation-serif/LiberationSerif-Regular.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf",
    "/usr/share/fonts/dejavu-serif-fonts/DejaVuSerif.ttf",
]

MONTHS = {
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
    "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
}


def find_font():
    for p in DEFAULT_FONT_CANDIDATES:
        if os.path.exists(p):
            return p
    raise FileNotFoundError("No serif font found; install liberation-serif fonts.")


def parse_perday(ods_path):
    """Return {(month, day): [honor, ...]} from the per-day section of the sheet."""
    df = pd.read_excel(ods_path, sheet_name="Names_organized", engine="odf", header=None)
    mapping = {}
    current_month = None
    for _, row in df.iterrows():
        c0, c1, c2 = row[0], row[1], row[2]
        if isinstance(c0, str) and c0.strip().lower() in MONTHS:
            current_month = MONTHS[c0.strip().lower()]
        day = None
        if pd.notna(c1):
            try:
                day = int(float(c1))
            except (ValueError, TypeError):
                day = None
        honor = c2.strip() if isinstance(c2, str) and c2.strip() else None
        if current_month and day and honor:
            mapping.setdefault((current_month, day), []).append(honor)
    return mapping


def build_honor_text(honors):
    if not honors:
        return None
    if len(honors) == 1:
        return honors[0]
    if len(honors) == 2:
        return honors[0] + " and " + honors[1]
    return ", ".join(honors[:-1]) + ", and " + honors[-1]


def wrap_text(draw, text, font, max_w):
    words, lines, cur = text.split(), [], ""
    for w in words:
        trial = (cur + " " + w).strip()
        if draw.textlength(trial, font=font) <= max_w or not cur:
            cur = trial
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def layout_lines(draw, full_line, font_path, max_w, max_h):
    for size in range(BASE_SIZE, MIN_SIZE - 1, -1):
        font = ImageFont.truetype(font_path, size)
        lines = wrap_text(draw, full_line, font, max_w)
        asc, desc = font.getmetrics()
        line_h = asc + desc
        gap = int(line_h * 0.12)
        block_h = len(lines) * line_h + (len(lines) - 1) * gap
        if block_h <= max_h:
            return font, lines, line_h, gap
    font = ImageFont.truetype(font_path, MIN_SIZE)
    lines = wrap_text(draw, full_line, font, max_w)
    asc, desc = font.getmetrics()
    line_h = asc + desc
    return font, lines, line_h, int(line_h * 0.12)


def repaint_background(im, box):
    """Seamlessly clear a central region by reconstructing the background gradient
    per-row from clean columns just inside the box's left/right edges."""
    x0, y0, x1, y1 = box
    a = np.array(im)
    left = a[y0:y1, x0 + 4:x0 + 34].reshape((y1 - y0), -1, 3)
    right = a[y0:y1, x1 - 34:x1 - 4].reshape((y1 - y0), -1, 3)
    both = np.concatenate([left, right], axis=1)
    row_bg = np.median(both, axis=1).astype(np.uint8)
    for i in range(y1 - y0):
        a[y0 + i, x0:x1] = row_bg[i]
    return Image.fromarray(a)


def render(img_path, honors, out_path, font_path):
    im = Image.open(img_path).convert("RGB")
    im = repaint_background(im, TITLE_BOX)   # delete line 1 ("Thank You <donor name>")
    im = repaint_background(im, COVER_BOX)   # clear old line 3 before redrawing the honor
    draw = ImageDraw.Draw(im)

    honor = build_honor_text(honors)
    full_line = f"in honor of {honor}." if honor else "in honor of this day."

    max_h = MAX_BLOCK_BOTTOM - MAX_BLOCK_TOP
    font, lines, line_h, gap = layout_lines(draw, full_line, font_path, MAX_TEXT_W, max_h)

    block_h = len(lines) * line_h + (len(lines) - 1) * gap
    top = LINE3_CENTER_Y - block_h // 2
    top = max(MAX_BLOCK_TOP, min(top, MAX_BLOCK_BOTTOM - block_h))

    y = top
    for ln in lines:
        w = draw.textlength(ln, font=font)
        draw.text((CENTER_X - w / 2, y), ln, font=font, fill=NAVY)
        y += line_h + gap

    im.save(out_path, "JPEG", quality=92)
    return len(lines), font.size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ods", default="Parness Hayom names 2026.ods")
    ap.add_argument("--src", default="pics/output_days_jpg")
    ap.add_argument("--out", default="output_with_honors")
    ap.add_argument("--font", default=None)
    args = ap.parse_args()

    font_path = args.font or find_font()
    os.makedirs(args.out, exist_ok=True)
    perday = parse_perday(args.ods)
    files = sorted(glob.glob(f"{args.src}/*.jpg"))

    summary, n_honor = {}, 0
    for f in files:
        date = os.path.basename(f)[:-4]
        _, m, d = map(int, date.split("-"))
        honors = perday.get((m, d), [])
        n_honor += 1 if honors else 0
        nlines, size = render(f, honors, os.path.join(args.out, os.path.basename(f)), font_path)
        summary[date] = {"honors": honors, "lines": nlines, "font": size}

    with open(os.path.join(args.out, "generation_summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, ensure_ascii=False, indent=1)
    print(f"Generated {len(files)} images into {args.out}/  ({n_honor} with honors, "
          f"{len(files) - n_honor} clean).")


if __name__ == "__main__":
    main()

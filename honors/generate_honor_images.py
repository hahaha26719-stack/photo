#!/usr/bin/env python3
"""
Compose the daily "Parness Hayom" sponsorship slides from pics.zip
(output_days_jpg/YYYY-MM-DD.jpg, 1920x1080) using the honors listed in the
"Names_organized" sheet of `Parness Hayom names 2026.ods`.

The original template had three placeholder lines:
    Thank You <donor name>
    for sponsoring <Date>
    in honor of <honor>.

The per-day section of the sheet provides honors only (no donor names), so this
script drops the donor line and re-composes each slide as a clean, centered card:

    Sponsored for
    <Month D, YYYY>
    ------------
    <naturally-phrased honor(s)>

Honor phrasing is normalized so it reads well:
    "Yahrzeit of X"      -> "In memory of X"          (a yahrzeit is a memorial)
    "Birthday of X"      -> "In honor of the birthday of X"
    "Anniversary of X"   -> "In honor of the anniversary of X"
    "Bar Mitzvah of X"   -> "In honor of the Bar Mitzvah of X"
    "In memory/honor of..." (already prefixed) -> kept verbatim
Multiple honors on one day are grouped: all memorials under one "In memory of ..."
clause and all celebrations under one "In honor of ..." clause.

Honors are keyed by calendar month+day (recurring annually); slides run
Sep 2026 -> Jun 2027 so the month/day match is all that is needed.

Usage:
    python3 generate_honor_images.py \
        --ods "Parness Hayom names 2026.ods" \
        --src pics/output_days_jpg \
        --out output_with_honors

Requires: pandas, odfpy, Pillow and a Liberation Serif (or Times) TTF.
"""
import os
import re
import glob
import json
import argparse
import datetime

import pandas as pd
from PIL import Image, ImageDraw, ImageFont
import numpy as np

# ---- template geometry (measured from the 1920x1080 slides) ----
CENTER_X = 960
# The full open area between the logo (ends ~y253) and the gold olive branch
# (~y896). We clear the two old text lines and compose fresh inside this band.
CLEAR_BOXES = [
    (300, 355, 1625, 495),   # old line 1  "Thank You <donor name>"
    (300, 520, 1625, 640),   # old line 2  "for sponsoring <date>"
    (285, 655, 1635, 885),   # old line 3  "in honor of <honor>."
]
CONTENT_TOP = 330
CONTENT_BOTTOM = 865
MAX_TEXT_W = 1330

NAVY = (20, 32, 60)
GOLD = (150, 120, 60)

DATE_LABEL_SIZE = 46      # "Sponsored for"
DATE_SIZE = 96            # the date, the visual headline
HONOR_SIZE = 74          # honor body, auto-shrinks to fit
HONOR_MIN = 34

DEFAULT_FONT_CANDIDATES = [
    "/usr/share/fonts/liberation-serif/LiberationSerif-Regular.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf",
    "/usr/share/fonts/dejavu-serif-fonts/DejaVuSerif.ttf",
]
BOLD_FONT_CANDIDATES = [
    "/usr/share/fonts/liberation-serif/LiberationSerif-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSerif-Bold.ttf",
    "/usr/share/fonts/dejavu-serif-fonts/DejaVuSerif-Bold.ttf",
]
ITALIC_FONT_CANDIDATES = [
    "/usr/share/fonts/liberation-serif/LiberationSerif-Italic.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSerif-Italic.ttf",
    "/usr/share/fonts/dejavu-serif-fonts/DejaVuSerif-Italic.ttf",
]

MONTHS = {
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
    "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
}


def _pick(cands):
    for p in cands:
        if os.path.exists(p):
            return p
    raise FileNotFoundError(f"None of these fonts found: {cands}")


def find_fonts():
    return _pick(DEFAULT_FONT_CANDIDATES), _pick(BOLD_FONT_CANDIDATES), _pick(ITALIC_FONT_CANDIDATES)


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


# ---- honor phrasing -------------------------------------------------------

def _subject_after(honor, keyword):
    """Return the text after 'keyword of ' (case-insensitive)."""
    m = re.match(rf"{keyword}\s+of\s+(.*)", honor, re.IGNORECASE)
    return m.group(1).strip() if m else None


def classify(honor):
    """Return (kind, phrase_fragment) where kind is 'memory' or 'honor'.
    fragment is the subject clause to slot into a combined sentence."""
    h = honor.strip()
    low = h.lower()

    # already-prefixed, keep verbatim as its own standalone sentence
    if low.startswith(("in memory of", "in honor of", "dedicated", "in appreciation",
                        "yahrzeit of", "yarzeit of")) and low.startswith(("in ", "dedicated")):
        # "In memory of ..." / "In honor of ..." / "Dedicated ..." / "In appreciation ..."
        kind = "memory" if low.startswith("in memory") else "honor"
        return kind, ("verbatim", h)

    # Yahrzeit / Yarzeit -> memorial
    subj = _subject_after(h, "Yahrzeit") or _subject_after(h, "Yarzeit")
    if subj:
        return "memory", ("subject", subj)

    subj = _subject_after(h, "Birthday")
    if subj:
        return "honor", ("subject", "the birthday of " + subj)
    subj = _subject_after(h, "Birthdays")
    if subj:
        return "honor", ("subject", "the birthdays of " + subj)

    subj = _subject_after(h, "Anniversary")
    if subj:
        return "honor", ("subject", "the anniversary of " + subj)

    m = re.match(r"Bar Mitzvah\s+of\s+(.*)", h, re.IGNORECASE)
    if m:
        return "honor", ("subject", "the Bar Mitzvah of " + m.group(1).strip())

    # fallback: treat as an honor subject verbatim
    return "honor", ("verbatim", h)


def _join(items):
    items = [i for i in items if i]
    if not items:
        return ""
    if len(items) == 1:
        return items[0]
    if len(items) == 2:
        return items[0] + " and " + items[1]
    return ", ".join(items[:-1]) + ", and " + items[-1]


def build_honor_sentences(honors):
    """Return a list of sentences (strings) phrased naturally from the honors."""
    if not honors:
        return ["In honor of this special day."]

    verbatim = []          # standalone sentences kept as-is
    mem_subjects = []      # subjects to fold into "In memory of ..."
    hon_subjects = []      # subjects to fold into "In honor of ..."

    for h in honors:
        kind, (mode, val) = classify(h)
        if mode == "verbatim":
            v = val.rstrip(".")
            verbatim.append(v)
        elif kind == "memory":
            mem_subjects.append(val)
        else:
            hon_subjects.append(val)

    sentences = []
    if mem_subjects:
        sentences.append("In memory of " + _join(mem_subjects))
    if hon_subjects:
        sentences.append("In honor of " + _join(hon_subjects))
    sentences.extend(verbatim)

    # add trailing period to each sentence
    return [s.rstrip(".") + "." for s in sentences]


# ---- text layout ----------------------------------------------------------

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


def layout_paragraph(draw, sentences, font_path, size, max_w):
    """Wrap all sentences into physical lines at the given size."""
    font = ImageFont.truetype(font_path, size)
    all_lines = []
    for s in sentences:
        all_lines.extend(wrap_text(draw, s, font, max_w))
    asc, desc = font.getmetrics()
    line_h = asc + desc
    return font, all_lines, line_h


def repaint_background(im, box):
    """Seamlessly clear a region by reconstructing the background gradient per-row
    from clean columns just inside the box's left/right edges."""
    x0, y0, x1, y1 = box
    a = np.array(im)
    left = a[y0:y1, x0 + 4:x0 + 34].reshape((y1 - y0), -1, 3)
    right = a[y0:y1, x1 - 34:x1 - 4].reshape((y1 - y0), -1, 3)
    both = np.concatenate([left, right], axis=1)
    row_bg = np.median(both, axis=1).astype(np.uint8)
    for i in range(y1 - y0):
        a[y0 + i, x0:x1] = row_bg[i]
    return Image.fromarray(a)


def draw_centered(draw, text, font, y, fill):
    w = draw.textlength(text, font=font)
    draw.text((CENTER_X - w / 2, y), text, font=font, fill=fill)


def render(img_path, honors, date_str, out_path, fonts):
    reg_path, bold_path, ital_path = fonts
    im = Image.open(img_path).convert("RGB")
    for box in CLEAR_BOXES:
        im = repaint_background(im, box)
    draw = ImageDraw.Draw(im)

    label_font = ImageFont.truetype(ital_path, DATE_LABEL_SIZE)
    date_font = ImageFont.truetype(bold_path, DATE_SIZE)

    label = "Sponsored for"
    la, ld = label_font.getmetrics(); label_h = la + ld
    da, dd = date_font.getmetrics(); date_h = da + dd

    sentences = build_honor_sentences(honors)

    # choose honor size that fits width and total height
    avail_h = CONTENT_BOTTOM - CONTENT_TOP
    gap_label_date = 6
    gap_date_rule = 34
    gap_rule_honor = 42
    rule_h = 2

    chosen = None
    for size in range(HONOR_SIZE, HONOR_MIN - 1, -1):
        hfont, hlines, hline_h = layout_paragraph(draw, sentences, reg_path, size, MAX_TEXT_W)
        hgap = int(hline_h * 0.14)
        honor_block_h = len(hlines) * hline_h + (len(hlines) - 1) * hgap
        total = (label_h + gap_label_date + date_h + gap_date_rule + rule_h
                 + gap_rule_honor + honor_block_h)
        if total <= avail_h:
            chosen = (hfont, hlines, hline_h, hgap, honor_block_h, total)
            break
    if chosen is None:
        hfont, hlines, hline_h = layout_paragraph(draw, sentences, reg_path, HONOR_MIN, MAX_TEXT_W)
        hgap = int(hline_h * 0.14)
        honor_block_h = len(hlines) * hline_h + (len(hlines) - 1) * hgap
        total = (label_h + gap_label_date + date_h + gap_date_rule + rule_h
                 + gap_rule_honor + honor_block_h)
        chosen = (hfont, hlines, hline_h, hgap, honor_block_h, total)

    hfont, hlines, hline_h, hgap, honor_block_h, total = chosen

    # vertically center the whole composed block in the content band
    y = CONTENT_TOP + (avail_h - total) // 2

    draw_centered(draw, label, label_font, y, GOLD)
    y += label_h + gap_label_date
    draw_centered(draw, date_str, date_font, y, NAVY)
    y += date_h + gap_date_rule

    # decorative gold rule under the date
    rule_w = 300
    draw.rectangle((CENTER_X - rule_w // 2, y, CENTER_X + rule_w // 2, y + rule_h), fill=GOLD)
    y += rule_h + gap_rule_honor

    for ln in hlines:
        draw_centered(draw, ln, hfont, y, NAVY)
        y += hline_h + hgap

    im.save(out_path, "JPEG", quality=92)
    return len(hlines), hfont.size


def format_date(date_iso):
    y, m, d = map(int, date_iso.split("-"))
    return datetime.date(y, m, d).strftime("%B %-d, %Y")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ods", default="Parness Hayom names 2026.ods")
    ap.add_argument("--src", default="pics/output_days_jpg")
    ap.add_argument("--out", default="output_with_honors")
    args = ap.parse_args()

    fonts = find_fonts()
    os.makedirs(args.out, exist_ok=True)
    perday = parse_perday(args.ods)
    files = sorted(glob.glob(f"{args.src}/*.jpg"))

    summary, n_honor = {}, 0
    for f in files:
        date_iso = os.path.basename(f)[:-4]
        _, m, d = map(int, date_iso.split("-"))
        honors = perday.get((m, d), [])
        n_honor += 1 if honors else 0
        date_str = format_date(date_iso)
        nlines, size = render(f, honors, date_str,
                              os.path.join(args.out, os.path.basename(f)), fonts)
        summary[date_iso] = {
            "honors": honors,
            "phrased": build_honor_sentences(honors),
            "lines": nlines,
            "font": size,
        }

    with open(os.path.join(args.out, "generation_summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, ensure_ascii=False, indent=1)
    print(f"Generated {len(files)} images into {args.out}/  ({n_honor} with honors, "
          f"{len(files) - n_honor} without).")


if __name__ == "__main__":
    main()

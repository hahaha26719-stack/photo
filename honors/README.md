# Honors integrated into the daily sponsorship slides

This folder holds the result of merging the honors from
`Names_organized` (in `Parness Hayom names 2026.ods`) into the daily
"Thank You / for sponsoring / in honor of" slides shipped in `pics.zip`
(`output_days_jpg/YYYY-MM-DD.jpg`, 1920×1080).

## What was done

Every slide's third line originally read **`in honor of <honor>.`** with a
literal placeholder. For each date, the `<honor>` placeholder was replaced with
the honor(s) the sheet lists for that calendar day, redrawn in a matching serif
font (Liberation Serif ≈ Times New Roman), the same navy color, centering, and
vertical position as the template — with a seamless background repaint so no
placeholder text or edit box remains.

- **303 slides** processed: **2026-09-01 → 2027-06-30**.
- **136 slides** got one or more real honors from the sheet.
- **167 slides** had no honor listed for that day and were given a clean
  `in honor of this day.` line (removing the `<honor>` placeholder).
- Days with multiple honors are combined naturally (`A and B`, or
  `A, B, and C`); long text auto-wraps and the font auto-shrinks (79→down)
  to stay inside the frame and above the gold olive-branch decoration.

Honors in the sheet are keyed by **month + day** (recurring annually), so
Sep–Dec map to the 2026 rows and Jan–Jun to the 2027 rows.

## Files

- `generate_honor_images.py` — reproducible generator (see header for usage).
- `honors_map.json` — the parsed `date → [honors]` mapping used.
- `output_with_honors.zip` — all 303 finished JPEGs (same `YYYY-MM-DD.jpg`
  names as the source, ready to drop into the photo-frame slideshow).

## Regenerate

```bash
pip install pandas odfpy Pillow
# from a dir containing the .ods and pics/output_days_jpg/*.jpg
python3 generate_honor_images.py \
    --ods "Parness Hayom names 2026.ods" \
    --src pics/output_days_jpg \
    --out output_with_honors
```

## Note on `<donor name>`

The first line still reads **`Thank You <donor name>`**. The per-day section of
`Names_organized` lists **honors only** — it has no donor name for each day — so
that placeholder was intentionally left untouched. If you have a
date → donor-name list, the same script can fill line 1 the same way.

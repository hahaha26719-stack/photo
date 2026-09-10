# Parness Hayom daily slides — honors integrated

This folder holds the result of re-composing the daily "Parness Hayom"
sponsorship slides shipped in `pics.zip` (`output_days_jpg/YYYY-MM-DD.jpg`,
1920×1080) using the honors from the `Names_organized` sheet of
`Parness Hayom names 2026.ods`.

## What was done

The original template had three placeholder lines:

```
Thank You <donor name>
for sponsoring <Date>
in honor of <honor>.
```

The per-day section of the sheet lists **honors only** (no donor names), so the
donor line was dropped and each slide re-composed as a clean, centered card that
fills the space and reads naturally:

```
        Sponsored for          (gold italic label)
       <Month D, YYYY>         (bold headline)
        ── gold rule ──
   <naturally-phrased honor(s)>
```

Everything is redrawn in the template's serif (Liberation Serif ≈ Times New
Roman), navy `#14203C`, centered, with a seamless per-row background repaint so
no old text or edit box shows through. The block is vertically centered in the
open area between the logo and the gold olive-branch decoration.

### Honor phrasing

Raw sheet entries are normalized so the sentence reads well (no more
"in honor of Yahrzeit of …"):

| Sheet entry              | Rendered as                              |
|--------------------------|------------------------------------------|
| `Yahrzeit of X`          | `In memory of X`                         |
| `Birthday of X`          | `In honor of the birthday of X`          |
| `Anniversary of X`       | `In honor of the anniversary of X`       |
| `Bar Mitzvah of X`       | `In honor of the Bar Mitzvah of X`       |
| `In memory/honor of …`   | kept verbatim                            |

Days with **multiple honors** are grouped: all memorials fold into one
`In memory of A, B, and C.` sentence and all celebrations into one
`In honor of …` sentence. Long text auto-wraps and the honor font auto-shrinks
(74 → down) to stay inside the frame and above the olive branch.

## Results

- **303 slides**: 2026-09-01 → 2027-06-30.
- **136** slides have one or more honors from the sheet.
- **167** days had no honor listed → `In honor of this special day.`

## Files

- `generate_honor_images.py` — reproducible generator (see header for usage).
- `honors_map.json` — the parsed `date → [raw honors]` mapping.
- `generation_summary.json` — per-date raw honors, the phrased sentences, line
  count and font size actually used.
- `output_with_honors.zip` — all 303 finished JPEGs (same `YYYY-MM-DD.jpg`
  names as the source, ready to drop into the photo-frame slideshow).

## Regenerate

```bash
pip install pandas odfpy Pillow
sudo dnf install -y liberation-serif-fonts   # or install Liberation/Times serif
# from a dir containing the .ods and pics/output_days_jpg/*.jpg
python3 generate_honor_images.py \
    --ods "Parness Hayom names 2026.ods" \
    --src pics/output_days_jpg \
    --out output_with_honors
```

## Adding donor names later

If you get a date → donor-name list, the generator can render a donor line
above the date the same way — the layout already leaves room for it.

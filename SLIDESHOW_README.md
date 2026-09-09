# Pi Slideshow (`setup.sh`)

A one-shot setup script for a **Banana Pi P2 Zero** (or Raspberry Pi Zero) that
runs a **date-driven** photo slideshow with a **Tailscale-hosted web UI** for
uploading pictures and scheduling black-screen skips.

## Install (run once on the board)

```bash
apt update && apt install -y git      # git is needed to clone
git clone https://github.com/hahaha26719-stack/photo.git
cd photo
bash setup.sh                          # auto-detects your desktop user
tailscale up                           # authenticate (opens a login URL)
reboot
```

> If auto-detection picks the wrong user, run:
> `SLIDESHOW_USER=yourname bash setup.sh`

After reboot the attached screen shows a **test image** until you upload photos.
Get your web UI address with `tailscale ip -4` → `http://<ip>:5000`.

## How it works — DATE-DRIVEN

Name each photo by **the date it should appear**, in `YYYY-MM-DD` format:

```
2026-03-14.jpg   -> shows on 14 March 2026
2026-12-25.png   -> shows on 25 December 2026
2027-01-01.jpg   -> shows on 1 January 2027
```

Multi-year is fully supported (the year is in the name).

| Situation | On screen |
|-----------|-----------|
| A photo is named for today | That photo |
| **No** photo named for today | **Black screen** |
| Today is a **skipped** date | **Black screen** (even if a photo matches) |
| No photos uploaded at all | Test/placeholder image |

- The display re-checks every 60 seconds, so it switches to the new day's
  photo right at midnight on its own.
- Files **not** named `YYYY-MM-DD` are kept but never displayed; the web UI
  flags them with a red "bad name" tag.

## Web UI (`http://<tailscale-ip>:5000`)

- **Upload** one or more photos (name them `YYYY-MM-DD`)
- **Bulk delete** — tick checkboxes (or "Select all") then **Delete Selected**
- **Delete** a single photo with its row button
- **Schedule a skip** for any date, or remove one
- **Status** — today's date, what's playing now, photo count, skip count

## Files created on the board

| Path | Purpose |
|------|---------|
| `/opt/slideshow/app.py` | Flask web UI |
| `/opt/slideshow/advance.py` | Midnight cron — restarts display for the new date |
| `/opt/slideshow/display.sh` | Date-driven feh display loop |
| `/opt/slideshow/state.json` | Image list + skipped dates |
| `/opt/slideshow/images/` | Uploaded photos |
| `/etc/systemd/system/slideshow-web.service` | Web UI service |
| `/etc/systemd/system/slideshow-display.service` | Display service |
| `/etc/cron.d/slideshow-advance` | Midnight refresh |
| `/var/log/slideshow/` | Logs |

# Pi Slideshow (`setup.sh`)

A one-shot setup script for a **Raspberry Pi Zero 2** that runs a daily photo
slideshow with a **Tailscale-hosted web UI** for uploading pictures and
scheduling day skips.

## Install (run once on the Pi)

```bash
sudo bash setup.sh
sudo tailscale up      # if Tailscale isn't authenticated yet
sudo reboot
```

After reboot the screen shows a **test image** immediately (so you can confirm
the display works without waiting for midnight). Open the web UI from any device
on your tailnet and upload photos.

## Web UI

Reachable at `http://<tailscale-ip>:5000`:

- **Upload** one or more photos (PNG/JPG/GIF/BMP/WEBP)
- **Reorder** photos by drag-and-drop
- **Delete** photos
- **Schedule a skip** for any date, or remove one
- **Live status** — which photo is playing, today's date, skip count

## How it works

| Situation | On screen |
|-----------|-----------|
| Fresh setup, no photos yet | Test image ("Slideshow Ready") |
| You upload photos | Current photo — immediately |
| Normal day | Current photo |
| **Skipped date** | **Black screen for the whole day** |
| Midnight | Advances to the next photo (wraps around) |

- A midnight cron job (`advance.py`) **always** advances to the next photo.
- A **skipped date** does not stop advancing — instead the display shows a
  **black screen** that whole day. The rotation keeps moving underneath, so the
  next day shows the next photo.
- The display re-checks every 60 seconds, so it flips to/from black right at
  midnight even before the cron restart fires.

## Files created on the Pi

| Path | Purpose |
|------|---------|
| `/opt/slideshow/app.py` | Flask web UI |
| `/opt/slideshow/advance.py` | Midnight photo-advance (cron) |
| `/opt/slideshow/display.sh` | feh display loop |
| `/opt/slideshow/state.json` | Current index, skipped dates, image list |
| `/opt/slideshow/images/` | Uploaded photos |
| `/etc/systemd/system/slideshow-web.service` | Web UI service |
| `/etc/systemd/system/slideshow-display.service` | Display service |
| `/etc/cron.d/slideshow-advance` | Midnight cron |
| `/var/log/slideshow/` | Logs |

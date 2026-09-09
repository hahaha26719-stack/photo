#!/usr/bin/env bash
# =============================================================================
#  Raspberry Pi Zero 2 — Daily Slideshow Setup
#  Run once:  sudo bash setup.sh
# =============================================================================
set -e

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── must run as root ──────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Please run with sudo: sudo bash setup.sh"

# ── config ────────────────────────────────────────────────────────────────────
APP_DIR="/opt/slideshow"
IMG_DIR="$APP_DIR/images"
STATE_FILE="$APP_DIR/state.json"
LOG_DIR="/var/log/slideshow"
WEB_PORT=5000

# ── work out which desktop user runs the slideshow ───────────────────────────
# Priority:
#   1. SLIDESHOW_USER env var  (override: SLIDESHOW_USER=foo bash setup.sh)
#   2. SUDO_USER               (set when invoked via sudo)
#   3. first real login user in /home that has a passwd entry
# We then verify the chosen user actually exists.
pick_display_user() {
    local candidate=""
    if [[ -n "$SLIDESHOW_USER" ]]; then
        candidate="$SLIDESHOW_USER"
    elif [[ -n "$SUDO_USER" && "$SUDO_USER" != "root" ]]; then
        candidate="$SUDO_USER"
    else
        # first directory in /home that is also a valid user account
        for d in /home/*; do
            [[ -d "$d" ]] || continue
            local u; u="$(basename "$d")"
            if id "$u" &>/dev/null; then candidate="$u"; break; fi
        done
    fi
    echo "$candidate"
}

DISPLAY_USER="$(pick_display_user)"

if [[ -z "$DISPLAY_USER" ]] || ! id "$DISPLAY_USER" &>/dev/null; then
    error "Could not determine a valid desktop user. Re-run like:  SLIDESHOW_USER=sadya bash setup.sh"
fi

DISPLAY_HOME="$(getent passwd "$DISPLAY_USER" | cut -d: -f6)"
[[ -z "$DISPLAY_HOME" ]] && DISPLAY_HOME="/home/$DISPLAY_USER"

info "Slideshow will run as user: $DISPLAY_USER (home: $DISPLAY_HOME)"

# =============================================================================
#  1. SYSTEM PACKAGES
# =============================================================================
info "Updating package lists…"
apt-get update -qq

info "Installing system packages…"
apt-get install -y -qq \
    python3 python3-pip python3-venv python3-pil \
    feh \
    unclutter \
    xorg xinit openbox x11-xserver-utils \
    curl \
    jq

# =============================================================================
#  2. TAILSCALE  (skip if already installed)
# =============================================================================
if ! command -v tailscale &>/dev/null; then
    info "Installing Tailscale…"
    curl -fsSL https://tailscale.com/install.sh | sh
    info "Tailscale installed. Run 'sudo tailscale up' after this script finishes to authenticate."
else
    info "Tailscale already installed — skipping."
fi

# =============================================================================
#  3. DIRECTORY STRUCTURE
# =============================================================================
info "Creating directories…"
mkdir -p "$IMG_DIR" "$LOG_DIR"
chown -R "$DISPLAY_USER":"$DISPLAY_USER" "$APP_DIR" "$LOG_DIR"

# =============================================================================
#  4. PYTHON VIRTUAL-ENV + FLASK
# =============================================================================
info "Setting up Python virtual environment…"
# --system-site-packages lets the venv reuse the apt-installed python3-pil
# (Pillow), so we don't try to compile it from source (no C toolchain on the Pi).
python3 -m venv --system-site-packages "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
# Flask + Werkzeug are pure-Python (no compiler needed). Pillow comes from apt.
"$APP_DIR/venv/bin/pip" install --quiet flask werkzeug

# =============================================================================
#  5. INITIAL STATE FILE
# =============================================================================
if [[ ! -f "$STATE_FILE" ]]; then
    info "Creating initial state file…"
    cat > "$STATE_FILE" <<'JSON'
{
  "current_index": 0,
  "skipped_dates": [],
  "images": []
}
JSON
fi
chown "$DISPLAY_USER":"$DISPLAY_USER" "$STATE_FILE"

# =============================================================================
#  6. FLASK WEB APPLICATION
# =============================================================================
info "Writing Flask web app…"
cat > "$APP_DIR/app.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Slideshow Web UI
- Upload images (they are stored and sorted alphabetically / by upload order)
- Schedule a skip for a specific date
- View current status
- Reorder images via drag-and-drop
"""

import json, os, subprocess
from datetime import date, datetime
from flask import (Flask, render_template_string, request,
                   redirect, url_for, flash, jsonify, send_from_directory)
from werkzeug.utils import secure_filename

APP_DIR   = "/opt/slideshow"
IMG_DIR   = os.path.join(APP_DIR, "images")
STATE     = os.path.join(APP_DIR, "state.json")
ALLOWED   = {"png", "jpg", "jpeg", "gif", "bmp", "webp"}

app = Flask(__name__)
app.secret_key = "slideshow-secret-change-me"

# ── helpers ──────────────────────────────────────────────────────────────────
def load_state():
    with open(STATE) as f:
        return json.load(f)

def save_state(s):
    with open(STATE, "w") as f:
        json.dump(s, f, indent=2)

def allowed_file(filename):
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED

def reload_slideshow():
    """Tell the slideshow service to re-read the image list."""
    try:
        subprocess.run(["systemctl", "restart", "slideshow-display"], check=False)
    except Exception:
        pass

# ── HTML template ─────────────────────────────────────────────────────────────
HTML = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>📸 Slideshow Manager</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:system-ui,sans-serif;background:#111;color:#eee;padding:20px}
    h1{font-size:1.6rem;margin-bottom:20px;color:#7dd3fc}
    h2{font-size:1.1rem;margin:24px 0 10px;color:#93c5fd}
    .card{background:#1e293b;border-radius:10px;padding:16px;margin-bottom:20px}
    label{display:block;margin-bottom:6px;font-size:.85rem;color:#94a3b8}
    input,select{width:100%;padding:8px 10px;border-radius:6px;border:1px solid #334155;
      background:#0f172a;color:#eee;font-size:.95rem;margin-bottom:10px}
    button,input[type=submit]{background:#3b82f6;color:#fff;border:none;padding:9px 18px;
      border-radius:6px;cursor:pointer;font-size:.95rem;width:auto}
    button:hover,input[type=submit]:hover{background:#2563eb}
    .btn-danger{background:#ef4444}
    .btn-danger:hover{background:#dc2626}
    .btn-warn{background:#f59e0b}
    .btn-warn:hover{background:#d97706}
    .flash{padding:10px 14px;border-radius:6px;margin-bottom:16px;background:#166534;color:#bbf7d0}
    .flash.err{background:#7f1d1d;color:#fecaca}
    table{width:100%;border-collapse:collapse;font-size:.9rem}
    th,td{padding:8px 10px;text-align:left;border-bottom:1px solid #1e293b}
    th{color:#64748b;font-weight:600}
    tr:hover td{background:#1e293b}
    .badge{display:inline-block;padding:2px 8px;border-radius:20px;font-size:.75rem}
    .badge-blue{background:#1d4ed8;color:#bfdbfe}
    .badge-green{background:#166534;color:#bbf7d0}
    .badge-red{background:#7f1d1d;color:#fecaca}
    .status-box{display:grid;grid-template-columns:1fr 1fr;gap:12px}
    .stat{background:#0f172a;border-radius:8px;padding:12px 16px}
    .stat .val{font-size:1.4rem;font-weight:700;color:#7dd3fc}
    .stat .lbl{font-size:.8rem;color:#64748b;margin-top:2px}
    img.thumb{width:60px;height:40px;object-fit:cover;border-radius:4px}
    .drag-handle{cursor:grab;color:#475569;font-size:1.2rem;user-select:none}
    #img-list tr{transition:background .15s}
    #img-list tr.dragging{opacity:.4}
  </style>
</head>
<body>
<h1>📸 Slideshow Manager</h1>

{% for msg, cat in messages %}
  <div class="flash {% if cat=='error' %}err{% endif %}">{{ msg }}</div>
{% endfor %}

<!-- STATUS -->
<div class="card">
  <h2>Current Status</h2>
  <div class="status-box">
    <div class="stat">
      <div class="val">{{ today }}</div>
      <div class="lbl">Today's date</div>
    </div>
    <div class="stat">
      <div class="val">{{ playing_now }}</div>
      <div class="lbl">Playing now</div>
    </div>
    <div class="stat">
      <div class="val">{{ state.images|length }}</div>
      <div class="lbl">Photos scheduled</div>
    </div>
    <div class="stat">
      <div class="val">{{ state.skipped_dates|length }}</div>
      <div class="lbl">Skipped dates</div>
    </div>
  </div>
</div>

<!-- UPLOAD -->
<div class="card">
  <h2>Upload Images</h2>
  <form method="post" action="/upload" enctype="multipart/form-data">
    <label>Name each file YYYY-MM-DD (e.g. 2026-03-14.jpg) — it shows on that date. PNG, JPG, GIF, BMP, WEBP.</label>
    <input type="file" name="files" accept="image/*" multiple required>
    <input type="submit" value="Upload">
  </form>
</div>

<!-- SCHEDULE SKIP -->
<div class="card">
  <h2>Schedule a Skip</h2>
  <p style="font-size:.85rem;color:#94a3b8;margin-bottom:10px">
    On a skipped date the screen shows BLACK for the whole day, even if a photo
    is named for that date.
  </p>
  <form method="post" action="/skip">
    <label>Date to skip (YYYY-MM-DD)</label>
    <input type="date" name="skip_date" required>
    <input type="submit" value="Add Skip">
  </form>
  {% if state.skipped_dates %}
  <h2 style="margin-top:16px">Scheduled Skips</h2>
  <table>
    <tr><th>Date</th><th>Status</th><th></th></tr>
    {% for d in state.skipped_dates|sort %}
    <tr>
      <td>{{ d }}</td>
      <td>
        {% if d < today %}
          <span class="badge badge-green">Past</span>
        {% elif d == today %}
          <span class="badge badge-blue">Today</span>
        {% else %}
          <span class="badge badge-red">Future</span>
        {% endif %}
      </td>
      <td>
        <form method="post" action="/skip/delete" style="display:inline">
          <input type="hidden" name="skip_date" value="{{ d }}">
          <button class="btn-danger" style="padding:4px 10px;font-size:.8rem">Remove</button>
        </form>
      </td>
    </tr>
    {% endfor %}
  </table>
  {% endif %}
</div>

<!-- IMAGE LIST -->
<div class="card">
  <h2>Photos <span style="font-size:.8rem;color:#64748b">(each file must be named YYYY-MM-DD, e.g. 2026-03-14.jpg)</span></h2>
  {% if state.images %}
  <form method="post" action="/image/delete_bulk" id="bulk-form"
        onsubmit="return confirm('Delete the selected photo(s)? This cannot be undone.');">
    <table>
      <tr>
        <th><input type="checkbox" id="check-all" onclick="toggleAll(this)" style="width:auto;margin:0"></th>
        <th></th><th>Date</th><th>Filename</th><th></th>
      </tr>
      {% for row in photos %}
      <tr>
        <td><input type="checkbox" name="filenames" value="{{ row.name }}" class="row-check" style="width:auto;margin:0"></td>
        <td><img class="thumb" src="/image/{{ row.name }}" alt="{{ row.name }}"></td>
        <td>
          {% if row.date %}
            {{ row.date }}
            {% if row.date == today %}<span class="badge badge-blue" style="margin-left:6px">▶ Today</span>{% endif %}
          {% else %}
            <span class="badge badge-red">bad name</span>
          {% endif %}
        </td>
        <td>{{ row.name }}</td>
        <td>
          <form method="post" action="/image/delete" style="display:inline">
            <input type="hidden" name="filename" value="{{ row.name }}">
            <button class="btn-danger" style="padding:4px 10px;font-size:.8rem">Delete</button>
          </form>
        </td>
      </tr>
      {% endfor %}
    </table>
    <button type="submit" class="btn-danger" style="margin-top:12px">🗑 Delete Selected</button>
  </form>
  {% else %}
  <p style="color:#94a3b8;font-size:.9rem">No photos yet. Upload some above.</p>
  {% endif %}
</div>

<script>
function toggleAll(box){
  document.querySelectorAll('.row-check').forEach(c => c.checked = box.checked);
}
</script>
</body>
</html>
"""

# ── routes ────────────────────────────────────────────────────────────────────
def parse_date_from_name(name):
    """Return 'YYYY-MM-DD' if the filename (minus extension) is a valid date, else None."""
    base = os.path.splitext(name)[0]
    try:
        datetime.strptime(base, "%Y-%m-%d")
        return base
    except ValueError:
        return None

@app.route("/")
def index():
    state = load_state()
    today = date.today().isoformat()
    msgs  = []
    # pull flash messages from cookie-less param
    if request.args.get("msg"):
        msgs.append((request.args["msg"], request.args.get("cat", "ok")))

    imgs = state.get("images", [])
    # Build rows with parsed date, sorted so dated photos are in date order.
    photos = [{"name": n, "date": parse_date_from_name(n)} for n in imgs]
    photos.sort(key=lambda r: (r["date"] is None, r["date"] or r["name"]))

    # What is on screen today?
    skipped = state.get("skipped_dates", [])
    if today in skipped:
        playing_now = "BLACK (skipped)"
    else:
        match = next((r["name"] for r in photos if r["date"] == today), None)
        playing_now = match if match else ("test image" if not imgs else "BLACK (no photo today)")

    return render_template_string(HTML,
        state=state, today=today, photos=photos,
        messages=msgs, playing_now=playing_now)

@app.route("/upload", methods=["POST"])
def upload():
    files = request.files.getlist("files")
    if not files:
        return redirect(url_for("index", msg="No files selected", cat="error"))
    state = load_state()
    saved, bad = 0, []
    for f in files:
        if f and allowed_file(f.filename):
            name = secure_filename(f.filename)
            # Uploading the same date-name replaces that day's photo (overwrite).
            f.save(os.path.join(IMG_DIR, name))
            if name not in state["images"]:
                state["images"].append(name)
            saved += 1
            if parse_date_from_name(name) is None:
                bad.append(name)
    save_state(state)
    reload_slideshow()
    msg = f"Uploaded {saved} image(s)."
    cat = "ok"
    if bad:
        msg += (" WARNING: these are NOT named YYYY-MM-DD and will not display: "
                + ", ".join(bad))
        cat = "error"
    return redirect(url_for("index", msg=msg, cat=cat))

@app.route("/image/<filename>")
def serve_image(filename):
    return send_from_directory(IMG_DIR, filename)

def _remove_one(state, name):
    """Remove a single image from state + disk. Returns True if it existed."""
    if name in state["images"]:
        state["images"].remove(name)
        path = os.path.join(IMG_DIR, name)
        if os.path.exists(path):
            os.remove(path)
        return True
    return False

@app.route("/image/delete", methods=["POST"])
def delete_image():
    name  = request.form.get("filename", "")
    state = load_state()
    if _remove_one(state, name):
        save_state(state)
        reload_slideshow()
        return redirect(url_for("index", msg=f"Deleted {name}"))
    return redirect(url_for("index", msg="Image not found", cat="error"))

@app.route("/image/delete_bulk", methods=["POST"])
def delete_bulk():
    names = request.form.getlist("filenames")
    if not names:
        return redirect(url_for("index", msg="No photos selected", cat="error"))
    state = load_state()
    deleted = sum(1 for n in names if _remove_one(state, n))
    save_state(state)
    reload_slideshow()
    return redirect(url_for("index", msg=f"Deleted {deleted} photo(s)"))

@app.route("/skip", methods=["POST"])
def add_skip():
    d = request.form.get("skip_date", "")
    try:
        datetime.strptime(d, "%Y-%m-%d")
    except ValueError:
        return redirect(url_for("index", msg="Invalid date format", cat="error"))
    state = load_state()
    if d not in state["skipped_dates"]:
        state["skipped_dates"].append(d)
        save_state(state)
    return redirect(url_for("index", msg=f"Skip added for {d}"))

@app.route("/skip/delete", methods=["POST"])
def delete_skip():
    d = request.form.get("skip_date", "")
    state = load_state()
    if d in state["skipped_dates"]:
        state["skipped_dates"].remove(d)
        save_state(state)
    return redirect(url_for("index", msg=f"Skip removed for {d}"))

@app.route("/api/state")
def api_state():
    return jsonify(load_state())

if __name__ == "__main__":
    # bind to all interfaces so Tailscale can reach it
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)), debug=False)
PYEOF

chown "$DISPLAY_USER":"$DISPLAY_USER" "$APP_DIR/app.py"
info "Flask app written."

# =============================================================================
#  7. MIDNIGHT ADVANCE SCRIPT
# =============================================================================
info "Writing midnight advance script…"
cat > "$APP_DIR/advance.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Run at midnight via cron.
The slideshow is DATE-DRIVEN: each day it shows the photo whose filename is
that day's date (YYYY-MM-DD). There is nothing to "advance" — we just restart
the display service so it re-evaluates for the new date right at 00:00.
(The display also re-checks on its own every minute as a safety net.)
"""
import subprocess
from datetime import date

def main():
    print(f"[advance] {date.today().isoformat()}: restarting display for new date.")
    subprocess.run(["systemctl", "restart", "slideshow-display"], check=False)

if __name__ == "__main__":
    main()
PYEOF

chmod +x "$APP_DIR/advance.py"
chown "$DISPLAY_USER":"$DISPLAY_USER" "$APP_DIR/advance.py"

# =============================================================================
#  8. SLIDESHOW DISPLAY SCRIPT
# =============================================================================
info "Writing slideshow display script…"
cat > "$APP_DIR/display.sh" <<'BASH'
#!/usr/bin/env bash
# Reads state.json and decides what to show full-screen with feh:
#   - If TODAY is a scheduled skip date  -> show a BLACK screen.
#   - Otherwise                          -> show the current photo.
# Runs as the desktop user under X.

STATE="/opt/slideshow/state.json"
IMG_DIR="/opt/slideshow/images"
BLACK_IMG="/opt/slideshow/black.png"
TEST_IMG="/opt/slideshow/test.png"

export DISPLAY=:0

# Make sure the black + test placeholder images exist (created once).
python3 - <<'PYGEN' 2>/dev/null || true
try:
    from PIL import Image, ImageDraw, ImageFont
    import os

    W, H = 1920, 1080

    # --- solid black screen (used for skipped days / fallbacks) ---
    if not os.path.exists("/opt/slideshow/black.png"):
        Image.new("RGB", (W, H), (0, 0, 0)).save("/opt/slideshow/black.png")

    # --- friendly test/placeholder image (shown until you upload photos) ---
    if not os.path.exists("/opt/slideshow/test.png"):
        img = Image.new("RGB", (W, H), (20, 30, 55))
        d = ImageDraw.Draw(img)

        def load_font(size):
            for p in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
                      "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
                try:
                    return ImageFont.truetype(p, size)
                except Exception:
                    pass
            return ImageFont.load_default()

        big  = load_font(90)
        small = load_font(48)

        def centered(text, font, y, fill):
            bbox = d.textbbox((0, 0), text, font=font)
            tw = bbox[2] - bbox[0]
            d.text(((W - tw) / 2, y), text, font=font, fill=fill)

        centered("Slideshow Ready", big,  380, (125, 211, 252))
        centered("Upload your photos from the web UI", small, 520, (200, 210, 230))
        centered("This test image goes away once photos are added", small, 600, (120, 130, 150))
        img.save("/opt/slideshow/test.png")
except Exception:
    pass
PYGEN

# Hide mouse cursor
unclutter -idle 0 -root &

# Track which day / target we last displayed so we can refresh when the day rolls over.
LAST_SHOWN=""

show() {
    local target="$1"
    # Kill any existing feh so only one image is on screen
    pkill -x feh 2>/dev/null
    sleep 0.3
    echo "[display] Showing: $target"
    feh \
        --fullscreen \
        --no-menus \
        --hide-pointer \
        --zoom fill \
        --borderless \
        "$target" &
}

while true; do
    TODAY=$(date +%F)

    # Is today a skipped date?
    IS_SKIPPED=$(python3 -c "
import json
try:
    with open('$STATE') as f: s=json.load(f)
    print('yes' if '$TODAY' in s.get('skipped_dates', []) else 'no')
except Exception:
    print('no')
" 2>/dev/null)

    if [[ "$IS_SKIPPED" == "yes" ]]; then
        # Skipped date -> black screen all day
        TARGET="$BLACK_IMG"
    else
        # Date-driven: find the photo whose filename is TODAY's date
        # (e.g. 2026-03-14.jpg for 2026-03-14). If none matches -> black.
        # Special case: if NO photos exist at all yet, show the test image
        # so first boot confirms the screen works.
        IMG_NAME=$(python3 -c "
import json, os
IMG_DIR='$IMG_DIR'
today='$TODAY'
try:
    with open('$STATE') as f: s=json.load(f)
    imgs = s.get('images', [])
except Exception:
    imgs = []

# match a file named exactly today's date, any image extension
match=''
for name in imgs:
    base=os.path.splitext(name)[0]
    if base==today:
        match=name
        break

if match:
    print('PHOTO:'+match)
elif not imgs:
    print('TEST')          # nothing uploaded yet
else:
    print('BLACK')         # photos exist but none for today -> black
" 2>/dev/null)

        case "$IMG_NAME" in
            PHOTO:*)
                TARGET="$IMG_DIR/${IMG_NAME#PHOTO:}"
                [[ -f "$TARGET" ]] || TARGET="$BLACK_IMG"
                ;;
            TEST)
                if [[ -f "$TEST_IMG" ]]; then TARGET="$TEST_IMG"; else TARGET="$BLACK_IMG"; fi
                ;;
            *)
                TARGET="$BLACK_IMG"
                ;;
        esac
    fi

    # If a black image was requested but we never managed to generate one,
    # use xsetroot to paint the root window black as a fallback.
    if [[ "$TARGET" == "$BLACK_IMG" && ! -f "$BLACK_IMG" ]]; then
        pkill -x feh 2>/dev/null
        command -v xsetroot >/dev/null && xsetroot -solid black
        LAST_SHOWN="black-fallback-$TODAY"
        sleep 60
        continue
    fi

    # Only (re)launch feh if what we should show has changed
    KEY="$TODAY|$TARGET"
    if [[ "$KEY" != "$LAST_SHOWN" ]]; then
        show "$TARGET"
        LAST_SHOWN="$KEY"
    fi

    # Re-check once a minute so a midnight rollover flips to/from black
    # even if the cron restart hasn't fired yet.
    sleep 60
done
BASH

chmod +x "$APP_DIR/display.sh"
chown "$DISPLAY_USER":"$DISPLAY_USER" "$APP_DIR/display.sh"

# =============================================================================
#  9. SYSTEMD — WEB SERVICE
# =============================================================================
info "Writing systemd service: slideshow-web…"
cat > /etc/systemd/system/slideshow-web.service <<UNIT
[Unit]
Description=Slideshow Web UI (Flask)
After=network.target tailscaled.service
Wants=tailscaled.service

[Service]
Type=simple
User=$DISPLAY_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/app.py
Restart=always
RestartSec=5
StandardOutput=append:$LOG_DIR/web.log
StandardError=append:$LOG_DIR/web-error.log
Environment=PORT=$WEB_PORT

[Install]
WantedBy=multi-user.target
UNIT

# =============================================================================
#  10. SYSTEMD — DISPLAY SERVICE
# =============================================================================
info "Writing systemd service: slideshow-display…"
cat > /etc/systemd/system/slideshow-display.service <<UNIT
[Unit]
Description=Slideshow Display (feh)
After=graphical.target

[Service]
Type=simple
User=$DISPLAY_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=$DISPLAY_HOME/.Xauthority
ExecStart=$APP_DIR/display.sh
Restart=always
RestartSec=5
StandardOutput=append:$LOG_DIR/display.log
StandardError=append:$LOG_DIR/display-error.log

[Install]
WantedBy=graphical.target
UNIT

# =============================================================================
#  11. CRON — MIDNIGHT ADVANCE
# =============================================================================
info "Installing midnight cron job…"
CRON_LINE="0 0 * * * root $APP_DIR/venv/bin/python $APP_DIR/advance.py >> $LOG_DIR/advance.log 2>&1"
CRON_FILE="/etc/cron.d/slideshow-advance"
echo "$CRON_LINE" > "$CRON_FILE"
chmod 644 "$CRON_FILE"

# =============================================================================
#  12. AUTOSTART X ON BOOT (for Pi Zero — no desktop env needed)
# =============================================================================
info "Configuring auto-start X session for $DISPLAY_USER…"

PROFILE_LINE='[[ -z $DISPLAY && $XDG_VTNR -eq 1 ]] && startx -- -nocursor'
PROFILE_FILE="$DISPLAY_HOME/.bash_profile"

if ! grep -qF "startx" "$PROFILE_FILE" 2>/dev/null; then
    echo "" >> "$PROFILE_FILE"
    echo "# Auto-start X for slideshow" >> "$PROFILE_FILE"
    echo "$PROFILE_LINE" >> "$PROFILE_FILE"
    chown "$DISPLAY_USER":"$DISPLAY_USER" "$PROFILE_FILE"
fi

# Openbox autostart — launch the display service script directly under X
OPENBOX_DIR="$DISPLAY_HOME/.config/openbox"
mkdir -p "$OPENBOX_DIR"
cat > "$OPENBOX_DIR/autostart" <<OBAUTO
# Start the slideshow display
bash $APP_DIR/display.sh &
OBAUTO
chown -R "$DISPLAY_USER":"$DISPLAY_USER" "$OPENBOX_DIR"

# Enable auto-login on tty1 so X starts on boot
GETTY_OVERRIDE="/etc/systemd/system/getty@tty1.service.d"
mkdir -p "$GETTY_OVERRIDE"
cat > "$GETTY_OVERRIDE/autologin.conf" <<GETTY
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $DISPLAY_USER --noclear %I \$TERM
GETTY

# =============================================================================
#  13. ENABLE + START SERVICES
# =============================================================================
info "Reloading systemd and enabling services…"
systemctl daemon-reload
systemctl enable slideshow-web.service
systemctl enable slideshow-display.service
systemctl restart slideshow-web.service || true   # display needs X, skip for now

# =============================================================================
#  14. PRINT SUMMARY
# =============================================================================
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "not-yet-authenticated")

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           SLIDESHOW SETUP COMPLETE ✓                ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${YELLOW}Web UI:${NC}           http://${TAILSCALE_IP}:${WEB_PORT}"
echo -e "  ${YELLOW}Images folder:${NC}    $IMG_DIR"
echo -e "  ${YELLOW}State file:${NC}       $STATE_FILE"
echo -e "  ${YELLOW}Logs:${NC}             $LOG_DIR/"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "   1. If Tailscale shows 'not-yet-authenticated':"
echo -e "      sudo tailscale up"
echo -e "   2. Reboot to start the slideshow display:"
echo -e "      sudo reboot"
echo -e "      (Until you upload photos, a TEST IMAGE is shown right away"
echo -e "       so you can confirm the screen works — no waiting for midnight.)"
echo -e "   3. Open the Web UI from any device on your Tailscale network"
echo -e "      and upload your photos."
echo ""
echo -e "  ${YELLOW}How it works (DATE-DRIVEN):${NC}"
echo -e "   • Name each photo by the date it should appear: YYYY-MM-DD"
echo -e "     e.g. 2026-03-14.jpg shows on Mar 14 2026, 2027-01-01.jpg on"
echo -e "     Jan 1 2027. Multi-year is fine."
echo -e "   • Each day the screen shows the photo whose name is today's date."
echo -e "   • No photo for today  -> BLACK screen."
echo -e "   • A SKIPPED date      -> BLACK screen (even if a photo is named"
echo -e "     for that date)."
echo -e "   • The display re-checks every minute, so it changes right at"
echo -e "     midnight on its own."
echo ""
echo -e "  ${YELLOW}Web UI features:${NC}"
echo -e "   • Upload photos (named YYYY-MM-DD)"
echo -e "   • Bulk delete: tick checkboxes (or Select All) -> Delete Selected"
echo -e "   • Schedule / remove skip dates"
echo ""

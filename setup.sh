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
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet flask werkzeug pillow

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
      <div class="val">{{ state.current_index + 1 }} / {{ state.images|length }}</div>
      <div class="lbl">Current image slot</div>
    </div>
    <div class="stat">
      <div class="val">{{ today }}</div>
      <div class="lbl">Today's date</div>
    </div>
    <div class="stat">
      <div class="val">{{ current_image or '—' }}</div>
      <div class="lbl">Playing now</div>
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
    <label>Select one or more images (PNG, JPG, GIF, BMP, WEBP)</label>
    <input type="file" name="files" accept="image/*" multiple required>
    <input type="submit" value="Upload">
  </form>
</div>

<!-- SCHEDULE SKIP -->
<div class="card">
  <h2>Schedule a Skip</h2>
  <p style="font-size:.85rem;color:#94a3b8;margin-bottom:10px">
    On a skipped date the screen shows BLACK for the whole day. The photo
    rotation keeps advancing underneath, so the next day shows the next photo.
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
  <h2>Image Order <span style="font-size:.8rem;color:#64748b">(drag to reorder)</span></h2>
  <table>
    <tr><th>#</th><th></th><th>Filename</th><th>Actions</th></tr>
    <tbody id="img-list">
    {% for img in state.images %}
    <tr data-name="{{ img }}" draggable="true">
      <td>{{ loop.index }}</td>
      <td><img class="thumb" src="/image/{{ img }}" alt="{{ img }}"></td>
      <td>{{ img }}</td>
      <td>
        <form method="post" action="/image/delete" style="display:inline">
          <input type="hidden" name="filename" value="{{ img }}">
          <button class="btn-danger" style="padding:4px 10px;font-size:.8rem">Delete</button>
        </form>
        {% if loop.index0 == state.current_index %}
          <span class="badge badge-blue" style="margin-left:6px">▶ Now</span>
        {% endif %}
      </td>
    </tr>
    {% endfor %}
    </tbody>
  </table>
  {% if state.images %}
  <button onclick="saveOrder()" style="margin-top:12px;background:#059669">💾 Save Order</button>
  {% endif %}
</div>

<script>
// drag-and-drop reorder
let dragged = null;
document.querySelectorAll('#img-list tr').forEach(row => {
  row.addEventListener('dragstart', e => { dragged = row; row.classList.add('dragging'); });
  row.addEventListener('dragend',   e => row.classList.remove('dragging'));
  row.addEventListener('dragover',  e => { e.preventDefault(); row.style.borderTop='2px solid #3b82f6'; });
  row.addEventListener('dragleave', e => row.style.borderTop='');
  row.addEventListener('drop', e => {
    e.preventDefault(); row.style.borderTop='';
    if (dragged && dragged !== row)
      row.parentNode.insertBefore(dragged, row);
  });
});
function saveOrder() {
  const order = [...document.querySelectorAll('#img-list tr')].map(r => r.dataset.name);
  fetch('/reorder', {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({order})
  }).then(r => r.json()).then(d => {
    if (d.ok) location.reload();
    else alert('Error saving order');
  });
}
</script>
</body>
</html>
"""

# ── routes ────────────────────────────────────────────────────────────────────
@app.route("/")
def index():
    state = load_state()
    today = date.today().isoformat()
    msgs  = []
    # pull flash messages from cookie-less param
    if request.args.get("msg"):
        msgs.append((request.args["msg"], request.args.get("cat", "ok")))
    ci = state.get("current_index", 0)
    imgs = state.get("images", [])
    current_image = imgs[ci] if imgs and ci < len(imgs) else None
    return render_template_string(HTML,
        state=state, today=today,
        messages=msgs, current_image=current_image)

@app.route("/upload", methods=["POST"])
def upload():
    files = request.files.getlist("files")
    if not files:
        return redirect(url_for("index", msg="No files selected", cat="error"))
    state = load_state()
    saved = 0
    for f in files:
        if f and allowed_file(f.filename):
            name = secure_filename(f.filename)
            # avoid collisions
            base, ext = os.path.splitext(name)
            counter = 1
            while os.path.exists(os.path.join(IMG_DIR, name)):
                name = f"{base}_{counter}{ext}"
                counter += 1
            f.save(os.path.join(IMG_DIR, name))
            if name not in state["images"]:
                state["images"].append(name)
            saved += 1
    save_state(state)
    reload_slideshow()
    return redirect(url_for("index", msg=f"Uploaded {saved} image(s)"))

@app.route("/image/<filename>")
def serve_image(filename):
    return send_from_directory(IMG_DIR, filename)

@app.route("/image/delete", methods=["POST"])
def delete_image():
    name  = request.form.get("filename", "")
    state = load_state()
    if name in state["images"]:
        state["images"].remove(name)
        # keep index in bounds
        if state["current_index"] >= len(state["images"]):
            state["current_index"] = max(0, len(state["images"]) - 1)
        save_state(state)
        path = os.path.join(IMG_DIR, name)
        if os.path.exists(path):
            os.remove(path)
        reload_slideshow()
        return redirect(url_for("index", msg=f"Deleted {name}"))
    return redirect(url_for("index", msg="Image not found", cat="error"))

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

@app.route("/reorder", methods=["POST"])
def reorder():
    data  = request.get_json(force=True)
    order = data.get("order", [])
    state = load_state()
    # validate — only keep names that actually exist
    existing = set(state["images"])
    new_order = [n for n in order if n in existing]
    # figure out what was "current" and keep it current
    old_current = (state["images"][state["current_index"]]
                   if state["images"] else None)
    state["images"] = new_order
    if old_current and old_current in new_order:
        state["current_index"] = new_order.index(old_current)
    else:
        state["current_index"] = 0
    save_state(state)
    reload_slideshow()
    return jsonify(ok=True)

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
Always advances current_index by 1 (wraps around) — every single day.
A "skipped" date does NOT change advancing; it only causes the DISPLAY
to show a black screen for that day (handled in display.sh).
Then restart the display service so it re-evaluates what to show.
"""
import json, subprocess
from datetime import date

STATE = "/opt/slideshow/state.json"

def load():
    with open(STATE) as f: return json.load(f)

def save(s):
    with open(STATE, "w") as f: json.dump(s, f, indent=2)

def main():
    today = date.today().isoformat()
    s = load()

    images = s.get("images", [])
    if not images:
        print("[advance] No images configured.")
        # still restart so the display picks up a possible skip/black screen
        subprocess.run(["systemctl", "restart", "slideshow-display"], check=False)
        return

    old = s["current_index"]
    s["current_index"] = (old + 1) % len(images)
    save(s)
    print(f"[advance] {today}: advanced from {old} ({images[old]}) "
          f"→ {s['current_index']} ({images[s['current_index']]})")

    # Restart display so it re-checks skip status AND shows the new image
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
        TARGET="$BLACK_IMG"
    else
        # Current photo from state
        IMG_NAME=$(python3 -c "
import json
try:
    with open('$STATE') as f: s=json.load(f)
    imgs=s.get('images',[]); idx=s.get('current_index',0)
    print(imgs[idx] if imgs and idx < len(imgs) else '')
except Exception:
    print('')
" 2>/dev/null)

        if [[ -z "$IMG_NAME" ]]; then
            # No photos uploaded yet -> show the test image right away
            # (so you can confirm the display works without waiting for midnight).
            if [[ -f "$TEST_IMG" ]]; then
                TARGET="$TEST_IMG"
            else
                TARGET="$BLACK_IMG"
            fi
        else
            TARGET="$IMG_DIR/$IMG_NAME"
            [[ -f "$TARGET" ]] || TARGET="$BLACK_IMG"
        fi
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
echo -e "  ${YELLOW}How skips work:${NC}"
echo -e "   • Midnight cron runs advance.py every night at 00:00, always"
echo -e "     advancing to the next photo (wraps around at the end)."
echo -e "   • A SKIPPED date does NOT stop advancing — instead the display"
echo -e "     shows a BLACK screen for that whole day."
echo -e "   • The display also re-checks every minute, so it flips to/from"
echo -e "     black right at midnight even before the cron restart fires."
echo ""

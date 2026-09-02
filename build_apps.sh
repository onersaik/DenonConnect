#!/bin/bash
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
DOWNLOADS="$HOME/Downloads"

echo "=== STAGE CONNECT — build ==="

# ---- generate icon PNG via pure Python stdlib ----
gen_icon_png() {
    local OUT="$1"; local R=$2; local G=$3; local B=$4; local LABEL="$5"
    python3 - "$OUT" "$R" "$G" "$B" "$LABEL" << 'PY'
import sys, struct, zlib, math

out, _R, _G, _B, label = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
SZ = 1024
ORANGE = (0xF5, 0xA6, 0x23)
GREEN  = (0x00, 0xE6, 0x76)
BLACK  = (8, 8, 10)

def png(pixels):
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    rows = b''.join(b'\x00' + bytes(pixels[y*SZ*4:(y+1)*SZ*4]) for y in range(SZ))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', SZ, SZ, 8, 6, 0, 0, 0)) \
         + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b'')

px = bytearray(SZ * SZ * 4)

def put(x, y, r, g, b, a):
    if a <= 0 or x < 0 or y < 0 or x >= SZ or y >= SZ:
        return
    i = (y * SZ + x) * 4
    if a >= 255:
        px[i], px[i+1], px[i+2], px[i+3] = r, g, b, 255
        return
    oa = px[i+3]
    if oa == 0:
        px[i], px[i+1], px[i+2], px[i+3] = r, g, b, a
        return
    na = a + oa * (255 - a) // 255
    if na == 0:
        return
    inv = 255 - a
    px[i]   = (r * a + px[i]   * oa * inv // 255) // na
    px[i+1] = (g * a + px[i+1] * oa * inv // 255) // na
    px[i+2] = (b * a + px[i+2] * oa * inv // 255) // na
    px[i+3] = na

def fill_round_rect(x0, y0, x1, y1, rad, color, alpha=255):
    r, g, b = color
    for y in range(max(0, y0), min(SZ, y1 + 1)):
        for x in range(max(0, x0), min(SZ, x1 + 1)):
            cx = x0 + rad if x < x0 + rad else (x1 - rad if x > x1 - rad else x)
            cy = y0 + rad if y < y0 + rad else (y1 - rad if y > y1 - rad else y)
            if (x < x0 + rad or x > x1 - rad) and (y < y0 + rad or y > y1 - rad):
                d = math.hypot(x - cx, y - cy) - rad
                cov = max(0.0, min(1.0, 0.5 - d))
                if cov <= 0:
                    continue
                put(x, y, r, g, b, int(alpha * cov))
            else:
                put(x, y, r, g, b, alpha)

def stamp_disk(cx, cy, rad, color, alpha=255):
    r, g, b = color
    x0, x1 = int(cx - rad - 1), int(cx + rad + 2)
    y0, y1 = int(cy - rad - 1), int(cy + rad + 2)
    for y in range(y0, y1):
        for x in range(x0, x1):
            d = math.hypot(x + 0.5 - cx, y + 0.5 - cy) - rad
            cov = max(0.0, min(1.0, 0.5 - d))
            if cov > 0:
                put(x, y, r, g, b, int(alpha * cov))

def stroke_poly(pts, width, color, alpha=255):
    rad = width / 2.0
    for i in range(len(pts) - 1):
        x0, y0 = pts[i]
        x1, y1 = pts[i + 1]
        dx, dy = x1 - x0, y1 - y0
        dist = math.hypot(dx, dy)
        if dist < 1:
            stamp_disk(x0, y0, rad, color, alpha)
            continue
        n = max(2, int(dist / max(1.0, rad * 0.7)))
        for k in range(n + 1):
            t = k / n
            stamp_disk(x0 + dx * t, y0 + dy * t, rad, color, alpha)

def letter_S(x, y, w, h, color, sw):
    stroke_poly([
        (x + w, y + sw),
        (x + sw, y + sw),
        (x + sw, y + h * 0.48),
        (x + w - sw, y + h * 0.48),
        (x + w - sw, y + h - sw),
        (x + sw, y + h - sw),
    ], sw, color)

def letter_C(x, y, w, h, color, sw):
    stroke_poly([
        (x + w, y + sw),
        (x + sw, y + sw),
        (x + sw, y + h - sw),
        (x + w, y + h - sw),
    ], sw, color)

def letter_T(x, y, w, h, color, sw):
    stroke_poly([(x, y + sw), (x + w, y + sw)], sw, color)
    stroke_poly([(x + w * 0.5, y + sw), (x + w * 0.5, y + h - sw * 0.4)], sw, color)

def letter_E(x, y, w, h, color, sw):
    stroke_poly([(x + sw, y + sw), (x + sw, y + h - sw)], sw, color)
    stroke_poly([(x + sw, y + sw), (x + w, y + sw)], sw, color)
    stroke_poly([(x + sw, y + h * 0.5), (x + w * 0.85, y + h * 0.5)], sw, color)
    stroke_poly([(x + sw, y + h - sw), (x + w, y + h - sw)], sw, color)

# black rounded background
fill_round_rect(0, 0, SZ - 1, SZ - 1, SZ // 6, BLACK)

is_test = label.upper() == "TEST"
if is_test:
    # dashed orange border
    inset = 48
    rad = SZ // 6 - 8
    x0, y0, x1, y1 = inset, inset, SZ - 1 - inset, SZ - 1 - inset
    # walk rounded-rect perimeter
    def perimeter():
        pts = []
        steps = 360
        # approximate by sampling four sides + corners
        for i in range(steps):
            t = i / steps
            # 0-1 around rect
            peri = t * 4
            if peri < 1:  # top
                pts.append((x0 + rad + (x1 - x0 - 2 * rad) * peri, y0))
            elif peri < 2:
                pts.append((x1, y0 + rad + (y1 - y0 - 2 * rad) * (peri - 1)))
            elif peri < 3:
                pts.append((x1 - rad - (x1 - x0 - 2 * rad) * (peri - 2), y1))
            else:
                pts.append((x0, y1 - rad - (y1 - y0 - 2 * rad) * (peri - 3)))
        return pts
    pts = perimeter()
    dash, gap = 18, 12
    acc = 0
    drawing = True
    run = []
    for i in range(len(pts)):
        p = pts[i]
        if drawing:
            run.append(p)
        if i + 1 < len(pts):
            acc += math.hypot(pts[i+1][0] - p[0], pts[i+1][1] - p[1])
        limit = dash if drawing else gap
        if acc >= limit:
            if drawing and len(run) >= 2:
                stroke_poly(run, 18, ORANGE)
            drawing = not drawing
            acc = 0
            run = []
    if drawing and len(run) >= 2:
        stroke_poly(run, 18, ORANGE)

    # TEST
    letters = "TEST"
    gap_l = 36
    lw = 150
    lh = 280
    sw = 36
    total = len(letters) * lw + (len(letters) - 1) * gap_l
    ox = (SZ - total) / 2
    oy = (SZ - lh) / 2
    drawers = {'T': letter_T, 'E': letter_E, 'S': letter_S}
    for i, ch in enumerate(letters):
        drawers[ch](ox + i * (lw + gap_l), oy, lw, lh, ORANGE, sw)
else:
    # SC
    lw, lh, sw, gap_l = 280, 420, 52, 48
    total = 2 * lw + gap_l
    ox = (SZ - total) / 2 - 20
    oy = (SZ - lh) / 2
    letter_S(ox, oy, lw, lh, ORANGE, sw)
    letter_C(ox + lw + gap_l, oy, lw, lh, ORANGE, sw)
    # green "pulse" dot with glow
    dx, dy, rad = SZ - 210, 210, 42
    stamp_disk(dx, dy, rad * 2.2, GREEN, 40)
    stamp_disk(dx, dy, rad * 1.45, GREEN, 90)
    stamp_disk(dx, dy, rad, GREEN, 255)

with open(out, 'wb') as f:
    f.write(png(px))
PY
}

make_icns() {
    local NAME="$1"; local R=$2; local G=$3; local B=$4; local LABEL="$5"; local OUT="$6"
    local TMP; TMP=$(mktemp -d)
    local ICONSET="$TMP/$NAME.iconset"
    mkdir -p "$ICONSET"
    gen_icon_png "$TMP/base.png" $R $G $B "$LABEL"
    for SZ in 16 32 128 256 512; do
        sips -z $SZ $SZ "$TMP/base.png" --out "$ICONSET/icon_${SZ}x${SZ}.png" > /dev/null 2>&1
        local SZ2=$(( SZ * 2 ))
        sips -z $SZ2 $SZ2 "$TMP/base.png" --out "$ICONSET/icon_${SZ}x${SZ}@2x.png" > /dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$OUT"
    rm -rf "$TMP"
    echo "  Icono: $OUT"
}

make_app() {
    local BIN="$1"; local APPNAME="$2"; local BUNDLEID="$3"; local ICNS="$4"; local DEST="$5"
    local APP="$DEST/${APPNAME}.app"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$REPO/.build/release/$BIN" "$APP/Contents/MacOS/$BIN"
    chmod +x "$APP/Contents/MacOS/$BIN"
    [ -f "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
    cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>${BIN}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLEID}</string>
    <key>CFBundleName</key><string>${APPNAME}</string>
    <key>CFBundleDisplayName</key><string>${APPNAME}</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Necesario para conectar con reproductores DJ en la red local.</string>
    <key>NSBonjourServices</key><array><string>_stagelinq._tcp</string></array>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
</dict></plist>
PLIST
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
    echo "  Bundle: $APP"
}

echo "[1/4] Compilando..."
cd "$REPO"
swift build -c release

TMPICONS=$(mktemp -d)
echo "[2/4] Generando iconos..."
make_icns "StageConnect"     0  0 0 "CONNECT"  "$TMPICONS/SC.icns"
make_icns "StageConnectTest" 0  0 0 "TEST"     "$TMPICONS/SCT.icns"

echo "[3/4] Creando bundles en ~/Downloads..."
make_app "SC6000ConnectApp" "STAGE CONNECT"      "com.entikrecords.stageconnect"      "$TMPICONS/SC.icns"  "$DOWNLOADS"
make_app "DJSimulatorApp"   "STAGE CONNECT TEST" "com.entikrecords.stageconnect.test" "$TMPICONS/SCT.icns" "$DOWNLOADS"

rm -rf "$TMPICONS"

echo ""
echo "[4/4] Completado."
ls -lah "$DOWNLOADS/STAGE CONNECT.app/Contents/MacOS/" 2>/dev/null || true
ls -lah "$DOWNLOADS/STAGE CONNECT TEST.app/Contents/MacOS/" 2>/dev/null || true

#!/usr/bin/env bash
# End-to-end reproducible generator for monoid.build / monoid.zone #devices 3D showcase shots.
# Captures real 3x apps/mbui screens (EN + ZH), composites OS chrome, downloads official 3D CAD
# hardware models (Apple USDZ + Samsung GLB) and CC0 oak PBR textures, renders 2000x1500 studio
# plates in Blender 4.2+ Cycles (separating the Emit pass so OIDN never blurs UI text), and
# encodes 2000x1500 (2x) + 1000x750 (1x) WebPs into website/assets/shots/.
#
# Usage:
#   bash website/devices.sh
# Environment:
#   MBUI_MEDIA_RUNTIME  Optional prebuilt sffilm binary (skips wasm-film-build.sh)
#   BLENDER_BIN         Blender 4.2+ executable (default: blender)
#   MONOID_3D_CACHE     Directory caching downloaded official USDZ/GLB/PBR assets
#   SAMPLES             Cycles sample count (default: 48)
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH:${MOON_HOME:-$HOME/.moon}/bin"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MBUI="$ROOT/apps/mbui"
OUT="$ROOT/website/assets/shots"
SIZES_TXT="$ROOT/website/shots-sizes.txt"
CACHE="${MONOID_3D_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/monoid-3d-assets}"
BLENDER="${BLENDER_BIN:-blender}"
CHROMIUM="${CHROMIUM_BIN:-chromium}"
SAMPLES="${SAMPLES:-48}"

command -v "$BLENDER" >/dev/null || { echo "devices.sh: Blender 4.2+ is required (set BLENDER_BIN)" >&2; exit 1; }
command -v "$CHROMIUM" >/dev/null || { echo "devices.sh: chromium is required (set CHROMIUM_BIN)" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "devices.sh: ffmpeg is required" >&2; exit 1; }
command -v node >/dev/null || { echo "devices.sh: node is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "devices.sh: curl is required" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monoid-devices.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT

RAW="$WORK/raw"
SCREENS="$WORK/screens"
RENDERS="$WORK/renders"
mkdir -p "$RAW" "$SCREENS" "$RENDERS" "$CACHE/wood" "$OUT"

# 1. Capture real 3x apps/mbui screens (EN + ZH)
if [ -n "${MBUI_MEDIA_RUNTIME:-}" ]; then
  RUNTIME="$MBUI_MEDIA_RUNTIME"
else
  bash "$MBUI/scripts/wasm-film-build.sh" "$MBUI/out/wasm-film"
  RUNTIME="$MBUI/out/wasm-film/sffilm"
fi

cat > "$WORK/drive" <<'DR'
timeout 8000
wait 1000
exit
DR

cat > "$WORK/drive-duo" <<'DR'
timeout 8000
system {"bars":{"top":0,"bottom":0,"left":0,"right":84}}
system {"size_class":{"width":"regular","height":"regular"}}
system {"fold":{"hinge":"open","divisions":[{"x":460,"y":0,"w":30,"h":669}]}}
wait 800
tapxy 650 330
wait 700
exit
DR

for loc_tag in "en:en" "zh:zh-CN"; do
  tag="${loc_tag%%:*}"; loc="${loc_tag##*:}"
  echo "→ capturing 3x apps/mbui screens ($tag)"
  env MBUI_MEDIA_RUNTIME="$RUNTIME" MBUI_FIXTURE="chat-site-duo" MBUI_DARK="0" MBUI_LOCALE="$loc" \
    MBUI_FILM_ALLOW_CORNER_FAULTS="1" MBUI_WIN="951x669" MBUI_FILM_SCALE="3" \
    MBUI_FILM_PLATFORM="1" MBUI_NATIVE_INPUT="finger" MBUI_FILM_NAV_ABLE="1" \
    bash "$MBUI/scripts/media.sh" picture "$RAW/duo-${tag}.png" "$WORK/drive-duo" >/dev/null

  env MBUI_MEDIA_RUNTIME="$RUNTIME" MBUI_FIXTURE="chat-site-android" MBUI_DARK="0" MBUI_LOCALE="$loc" \
    MBUI_FILM_ALLOW_CORNER_FAULTS="1" MBUI_WIN="412x915" MBUI_FILM_SCALE="3" \
    MBUI_FILM_PLATFORM="2" MBUI_NATIVE_INPUT="finger" \
    bash "$MBUI/scripts/media.sh" picture "$RAW/android-${tag}.png" "$WORK/drive" >/dev/null

  env MBUI_MEDIA_RUNTIME="$RUNTIME" MBUI_FIXTURE="place-stations-site" MBUI_DARK="0" MBUI_LOCALE="$loc" \
    MBUI_FILM_ALLOW_CORNER_FAULTS="1" MBUI_WIN="980x625" MBUI_FILM_SCALE="3" \
    MBUI_FILM_PLATFORM="0" MBUI_NATIVE_INPUT="mouse" \
    bash "$MBUI/scripts/media.sh" picture "$RAW/desk-${tag}.png" "$WORK/drive" >/dev/null

  env MBUI_MEDIA_RUNTIME="$RUNTIME" MBUI_FIXTURE="chat-site-web" MBUI_DARK="0" MBUI_LOCALE="$loc" \
    MBUI_FILM_ALLOW_CORNER_FAULTS="1" MBUI_WIN="1140x680" MBUI_FILM_SCALE="3" \
    MBUI_FILM_PLATFORM="0" MBUI_NATIVE_INPUT="mouse" \
    bash "$MBUI/scripts/media.sh" picture "$RAW/web-${tag}.png" "$WORK/drive" >/dev/null
done

# 2. Composite 3x native OS chrome bars
CHROMIUM_BIN="$CHROMIUM" node "$ROOT/website/devices-chrome.mjs" "$RAW" "$SCREENS"

# 3. Download official manufacturer 3D CAD models + CC0 Wood094 oak PBR into $CACHE
fetch() {
  local dest=$1 url=$2
  [ -s "$dest" ] || { echo "→ downloading $(basename "$dest")"; curl -fsSL "$url" -o "$dest"; }
}
fetch "$CACHE/iphone-duo.usdz" \
  "https://www.apple.com/105/media/us/iphone-duo/2026/9305e4b9-72d9-4c05-9381-b572adadd5e5/ar/iPhone_Duo_e-sim_Star-White_Variant.usdz"
fetch "$CACHE/macbook-air-15-silver.usdz" \
  "https://www.apple.com/105/media/us/macbook-air/2025/0833fe28-c438-4dc4-8edc-e39ef30df5f9/ar/macbook-air-15in-silver.usdz"
fetch "$CACHE/studio-display.usdz" \
  "https://www.apple.com/105/media/us/studio-display/2026/fcc06a33-5854-47b3-bf6e-b8619f5a4f10/ar/studio-display.usdz"
fetch "$CACHE/galaxy-s25-ultra.glb" \
  "https://images.samsung.com/common/smartphones/models/galaxy-s25-ultra/galaxy-s25-ultra-titanium-silverblue.glb"

if [ ! -s "$CACHE/wood/Wood094_2K-JPG_Color.jpg" ]; then
  echo "→ downloading AmbientCG CC0 Wood094_2K-JPG"
  curl -fsSL "https://ambientcg.com/get?file=Wood094_2K-JPG.zip" -o "$WORK/wood.zip"
  unzip -qo "$WORK/wood.zip" -d "$CACHE/wood"
fi

cat > "$CACHE/iphone-duo-open.usda" <<'USDA'
#usda 1.0
(
    defaultPrim = "VozFyMVAwkoHjOE"
    metersPerUnit = 0.01
    upAxis = "Y"
)

def "VozFyMVAwkoHjOE" (
    prepend references = @./iphone-duo.usdz@
    variants = {
        string Color = "Star_White"
        string Pose = "Landscape"
    }
)
{
}
USDA

# 4. Render all 8 2000x1500 plates in Blender Cycles
"$BLENDER" -b -P "$ROOT/website/render-devices.py" -- \
  --models "$CACHE" \
  --screens "$SCREENS" \
  --out "$RENDERS" \
  --devices duo,android,desk,web \
  --langs en,zh \
  --size 2000x1500 \
  --samples "$SAMPLES"

# 5. Encode 2000x1500 (2x) + 1000x750 (1x) WebPs and record website/shots-sizes.txt
rm -f "$SIZES_TXT"
for dev in duo android desk web; do
  for lang in en zh; do
    name="${dev}-${lang}"
    src="$RENDERS/${name}.png"
    ffmpeg -nostdin -v error -y -i "$src" -c:v libwebp -quality 90 -compression_level 6 "$OUT/${name}.webp"
    ffmpeg -nostdin -v error -y -i "$src" -vf "scale=1000:750:flags=lanczos" -c:v libwebp -quality 88 -compression_level 6 "$OUT/${name}-1x.webp"
    b2="$(wc -c < "$OUT/${name}.webp" | tr -d ' ')"
    b1="$(wc -c < "$OUT/${name}-1x.webp" | tr -d ' ')"
    printf "%-14s 2000x1500  2x=%7dB  1x=%7dB\n" "$name" "$b2" "$b1" | tee -a "$SIZES_TXT"
  done
done

echo "✓ done: $SIZES_TXT"

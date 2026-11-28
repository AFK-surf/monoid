#!/usr/bin/env bash
# Regenerates the monoid.build / monoid.zone #devices shots (EN + ZH): captures real 3x apps/mbui screens, adds the
# OS chrome (website/devices-chrome.mjs), downloads the device models, renders each device in Blender Cycles
# (website/render-devices.py) at 3840x2880 and encodes 3840x2880 (2x) + 1280x960 (1x) WebPs into website/assets/shots/.
#
# Slots: duo = iPhone 18 Pro Max, android = Galaxy S25+, then the desktop app in a window as each system draws it:
# mac on a MacBook Air 15", linux on a light laptop, win on a graphite Windows laptop; web = the web app in a
# full-screen browser on a MacBook Air 15".
#
# Usage:
#   bash website/devices.sh
# Environment:
#   MBUI_MEDIA_RUNTIME  Optional prebuilt sffilm binary (skips wasm-film-build.sh)
#   BLENDER_BIN         Blender 4.2+ executable (default: blender); a GPU (OptiX/CUDA) is used when present
#   CHROMIUM_BIN        Chromium executable (default: chromium)
#   MONOID_3D_CACHE     Directory caching the downloaded models and HDRI
#   SAMPLES             Cycles sample count (default: 256)
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH:${MOON_HOME:-$HOME/.moon}/bin"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MBUI="$ROOT/apps/mbui"
OUT="$ROOT/website/assets/shots"
SIZES_TXT="$ROOT/website/shots-sizes.txt"
CACHE="${MONOID_3D_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/monoid-3d-assets}"
BLENDER="${BLENDER_BIN:-blender}"
CHROMIUM="${CHROMIUM_BIN:-chromium}"
SAMPLES="${SAMPLES:-256}"

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
mkdir -p "$RAW" "$SCREENS" "$RENDERS" "$CACHE" "$OUT"

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

for loc_tag in "en:en" "zh:zh-CN"; do
  tag="${loc_tag%%:*}"; loc="${loc_tag##*:}"
  echo "→ capturing 3x apps/mbui screens ($tag)"
  env MBUI_MEDIA_RUNTIME="$RUNTIME" MBUI_FIXTURE="chat-site-duo" MBUI_DARK="0" MBUI_LOCALE="$loc" \
    MBUI_FILM_ALLOW_CORNER_FAULTS="1" MBUI_WIN="390x796" MBUI_FILM_SCALE="3" \
    MBUI_FILM_PLATFORM="1" MBUI_NATIVE_INPUT="finger" \
    bash "$MBUI/scripts/media.sh" picture "$RAW/duo-${tag}.png" "$WORK/drive" >/dev/null

  env MBUI_MEDIA_RUNTIME="$RUNTIME" MBUI_FIXTURE="chat-site-android" MBUI_DARK="0" MBUI_LOCALE="$loc" \
    MBUI_FILM_ALLOW_CORNER_FAULTS="1" MBUI_WIN="390x802" MBUI_FILM_SCALE="3" \
    MBUI_FILM_PLATFORM="2" MBUI_NATIVE_INPUT="finger" \
    bash "$MBUI/scripts/media.sh" picture "$RAW/android-${tag}.png" "$WORK/drive" >/dev/null

  # macOS: an inset window with 16pt corners (the window's buttons are AppKit's, added by devices-chrome.mjs)
  env MBUI_MEDIA_RUNTIME="$RUNTIME" MBUI_FIXTURE="chat-site-mac" MBUI_DARK="0" MBUI_LOCALE="$loc" \
    MBUI_FILM_ALLOW_CORNER_FAULTS="1" MBUI_WIN="1280x800" MBUI_FILM_SCALE="2" \
    MBUI_FILM_PLATFORM="0" MBUI_FILM_INSET="1" MBUI_FILM_WINDOW_CORNER="16" MBUI_NATIVE_INPUT="mouse" \
    bash "$MBUI/scripts/media.sh" picture "$RAW/mac-${tag}.png" "$WORK/drive" >/dev/null

  # Linux (GTK): an inset window with square corners; the app draws its own minimize/maximize/close
  env MBUI_MEDIA_RUNTIME="$RUNTIME" MBUI_FIXTURE="chat-site-linux" MBUI_DARK="0" MBUI_LOCALE="$loc" \
    MBUI_FILM_ALLOW_CORNER_FAULTS="1" MBUI_WIN="1520x980" MBUI_FILM_SCALE="2" \
    MBUI_FILM_PLATFORM="5" MBUI_FILM_INSET="1" MBUI_FILM_WINDOW_CORNER="0" MBUI_NATIVE_INPUT="mouse" \
    bash "$MBUI/scripts/media.sh" picture "$RAW/linux-${tag}.png" "$WORK/drive" >/dev/null

  # Windows: an inset window with Windows 11's 8pt corners; the app draws its own minimize/maximize/close
  env MBUI_MEDIA_RUNTIME="$RUNTIME" MBUI_FIXTURE="chat-site-web" MBUI_DARK="0" MBUI_LOCALE="$loc" \
    MBUI_FILM_ALLOW_CORNER_FAULTS="1" MBUI_WIN="1520x980" MBUI_FILM_SCALE="2" \
    MBUI_FILM_PLATFORM="3" MBUI_FILM_INSET="1" MBUI_FILM_WINDOW_CORNER="8" MBUI_NATIVE_INPUT="mouse" \
    bash "$MBUI/scripts/media.sh" picture "$RAW/win-${tag}.png" "$WORK/drive" >/dev/null

  env MBUI_MEDIA_RUNTIME="$RUNTIME" MBUI_FIXTURE="chat-site-android" MBUI_DARK="0" MBUI_LOCALE="$loc" \
    MBUI_FILM_ALLOW_CORNER_FAULTS="1" MBUI_WIN="1470x882" MBUI_FILM_SCALE="2" \
    MBUI_FILM_PLATFORM="4" MBUI_NATIVE_INPUT="mouse" \
    bash "$MBUI/scripts/media.sh" picture "$RAW/web-${tag}.png" "$WORK/drive" >/dev/null
done

# 2. Composite 3x native OS chrome bars
CHROMIUM_BIN="$CHROMIUM" node "$ROOT/website/devices-chrome.mjs" "$RAW" "$SCREENS"

# 3. Download the device models and the studio HDRI into $CACHE
fetch() {
  local dest=$1 url=$2
  [ -s "$dest" ] || { echo "→ downloading $(basename "$dest")"; curl -fsSL "$url" -o "$dest"; }
}
fetch "$CACHE/iphone-18-pro.usdz" \
  "https://www.apple.com/105/media/us/iphone-18-pro/2026/591df885-5ee2-4173-86e6-401021249f7c/ar/iphone-18-pro-e-sim.usdz"
fetch "$CACHE/galaxy-s25-plus.glb" \
  "https://images.samsung.com/common/smartphones/models/galaxy-s25-plus/galaxy-s25-plus-navy.glb"
fetch "$CACHE/macbook-air-15-silver.usdz" \
  "https://www.apple.com/105/media/us/macbook-air/2025/0833fe28-c438-4dc4-8edc-e39ef30df5f9/ar/macbook-air-15in-silver.usdz"
# "Modern Slim Laptop" by Mraz3D, CC BY 4.0 (sketchfab.com/3d-models/modern-slim-laptop-fbf172f8b14241feab581dcb1fbcd475),
# from the Objaverse mirror; the site footer credits it.
fetch "$CACHE/slim-laptop.glb" \
  "https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-025/fbf172f8b14241feab581dcb1fbcd475.glb"
fetch "$CACHE/studio_small_09_4k.exr" \
  "https://dl.polyhaven.org/file/ph-assets/HDRIs/exr/4k/studio_small_09_4k.exr"

# 4. Render the 12 plates (3840x2880)
render() {
  "$BLENDER" -b -P "$ROOT/website/render-devices.py" -- --models "$CACHE" --size 3840x2880 --samples "$SAMPLES" "$@"
}
for lang in en zh; do
  render --device iphone --screen "$SCREENS/duo-$lang.png" --out "$RENDERS/duo-$lang.png" --fr 0.18 --k 1.4 --dist 51
  render --device android --screen "$SCREENS/android-$lang.png" --out "$RENDERS/android-$lang.png" --dist 51
  render --device mac --screen "$SCREENS/mac-$lang.png" --out "$RENDERS/mac-$lang.png" --dist 92 --tz -3.5 --ty -2
  render --device linux --screen "$SCREENS/linux-$lang.png" --out "$RENDERS/linux-$lang.png" --dist 90 --tz -3.5 --ty -2
  render --device windows --screen "$SCREENS/win-$lang.png" --out "$RENDERS/win-$lang.png" --dist 90 --tz -3.5 --ty -2
  render --device mac --screen "$SCREENS/web-$lang.png" --out "$RENDERS/web-$lang.png" --dist 92 --tz -3.5 --ty -2
done

# 5. Encode 3840x2880 (4K), 1920x1440 and 1280x960 (1x) WebPs (Lanczos, so the browser never shrinks the 4K plate
#    by 2-3x itself, which steps the edges) and record website/shots-sizes.txt
rm -f "$SIZES_TXT"
for dev in duo android mac linux win web; do
  for lang in en zh; do
    name="${dev}-${lang}"
    src="$RENDERS/${name}.png"
    ffmpeg -nostdin -v error -y -i "$src" -c:v libwebp -quality 90 -compression_level 6 "$OUT/${name}.webp"
    ffmpeg -nostdin -v error -y -i "$src" -vf "scale=1920:1440:flags=lanczos" -c:v libwebp -quality 90 -compression_level 6 "$OUT/${name}-1920.webp"
    ffmpeg -nostdin -v error -y -i "$src" -vf "scale=1280:960:flags=lanczos" -c:v libwebp -quality 90 -compression_level 6 "$OUT/${name}-1x.webp"
    b4="$(wc -c < "$OUT/${name}.webp" | tr -d ' ')"
    b2="$(wc -c < "$OUT/${name}-1920.webp" | tr -d ' ')"
    b1="$(wc -c < "$OUT/${name}-1x.webp" | tr -d ' ')"
    printf "%-14s 4k=%7dB  1920=%7dB  1x=%7dB\n" "$name" "$b4" "$b2" "$b1" | tee -a "$SIZES_TXT"
  done
done

echo "✓ done: $SIZES_TXT"

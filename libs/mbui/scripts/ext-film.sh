#!/bin/bash
# A scene of an app of a module outside this repository (MBUI_APP_MOD: its moon.work naming mbui, scripts/android.sh
# says more) drawn offscreen by mbui's film (src/film) into a picture or a film, with no bridge of the app's own: its
# package src/$APP is a main that gives its view to `@film.run`, built for this Mac as scripts/mac.sh builds it
# (moonc's C split and compiled in parallel, each unit kept by what it is made of: scripts/mbc), then run.
#   MBUI_APP_MOD=DIR APP=PKG scripts/ext-film.sh picture NAME DRIVE [PREPARE]   NAME.png
#   MBUI_APP_MOD=DIR APP=PKG scripts/ext-film.sh film NAME DRIVE [PREPARE]      NAME.mp4, NAME.mp4.last.png (its last
#                                                                               frame as drawn), NAME.mp4.textrec
# NAME is a name, written in MBUI_FILM_OUT (default the module's out/film), or a path ending in .png or .mp4. DRIVE and
# PREPARE are film's scripts; the scene's settings are film's MBUI_* (src/film/film.mbt's head says each), passed on as
# they are, MBUI_FILM_SCALE 3 unless said (a picture for people is drawn at 3). MODE=release|debug as mac.sh's
# (default release); MBUI_SKIP_BUILD=1 runs what was built last. What is written appears only once it is whole.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/env.sh"
ROOT=$(cd "$D/.." && pwd)
CALLER=$PWD
usage() { echo "usage: MBUI_APP_MOD=DIR APP=PKG ext-film.sh picture|film NAME DRIVE [PREPARE]" >&2; exit 2; }
[ "$#" -ge 3 ] && [ "$#" -le 4 ] || usage
[ "$(uname -s)" = Darwin ] || {
  echo "ext-film: the film draws with the Mac's renderer (src/host/apple_render.m): run it on a Mac" >&2
  exit 2
}
[ -n "${APP:-}" ] || { echo "ext-film: APP, the package under the module's src that runs @film.run" >&2; exit 2; }
case "$APP" in '' | *[!a-zA-Z0-9_/-]*) echo "ext-film: APP $APP is no package's name" >&2; exit 2 ;; esac
MOD=$(cd "${MBUI_APP_MOD:-$ROOT}" && pwd)
MODE=${MODE:-release}
kind=$1
case $kind in picture) ext=png ;; film) ext=mp4 ;; *) usage ;; esac
abs() { case $1 in /*) echo "$1" ;; *) echo "$CALLER/$1" ;; esac; }
drive=$(abs "$3")
[ -s "$drive" ] || { echo "ext-film: no drive script at $3" >&2; exit 2; }
prepare=
if [ -n "${4:-}" ]; then
  prepare=$(abs "$4")
  [ -s "$prepare" ] || { echo "ext-film: no preparation script at $4" >&2; exit 2; }
fi
case $2 in
  *.$ext) out=$(abs "$2") ;;
  */* | *.png | *.mp4 | '') echo "ext-film: NAME is a name or a path ending in .$ext" >&2; exit 2 ;;
  *) out=$(abs "${MBUI_FILM_OUT:-$MOD/out/film}")/$2.$ext ;;
esac

if [ "${MBUI_SKIP_BUILD:-0}" != 1 ]; then
  # (mac.sh's words on stderr: what is written on stdout is this script's alone)
  MBUI_APP_MOD=$MOD APP=$APP MODE=$MODE bash "$D/mac.sh" build >&2
fi
exe=$MOD/$(cd "$MOD" && pkg_build "$APP" native "$MODE")/$(basename "$APP").exe
[ -x "$exe" ] || { echo "ext-film: no program at $exe (built? MBUI_SKIP_BUILD=1 runs one built before)" >&2; exit 1; }

mkdir -p "$(dirname "$out")"
# (written beside it and moved in once whole: a failure leaves what was there)
work=$(mktemp -d "$out.XXXXXX")
trap 'rm -rf "$work"' EXIT
export MBUI_FILM_SCALE=${MBUI_FILM_SCALE:-3}
cd "$MOD"
if [ "$kind" = picture ]; then
  env MBUI_FILM= MBUI_FILM_LAST= MBUI_PICTURE="$work/out.png" MBUI_FILM_DRIVE="$drive" \
    MBUI_FILM_PREPARE="$prepare" "$exe"
  [ -s "$work/out.png" ] || { echo "ext-film: $APP drew no picture" >&2; exit 1; }
  mv -f "$work/out.png" "$out"
else
  env MBUI_PICTURE= MBUI_FILM="$work/out.mp4" MBUI_FILM_LAST="$work/last.png" MBUI_FILM_DRIVE="$drive" \
    MBUI_FILM_PREPARE="$prepare" "$exe"
  [ -s "$work/out.mp4" ] || { echo "ext-film: $APP made no film" >&2; exit 1; }
  [ ! -f "$work/last.png" ] || mv -f "$work/last.png" "$out.last.png"
  [ ! -f "$work/out.mp4.textrec" ] || mv -f "$work/out.mp4.textrec" "$out.textrec"
  mv -f "$work/out.mp4" "$out"
fi
echo "ext-film: $out"

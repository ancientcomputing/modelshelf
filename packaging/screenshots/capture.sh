#!/bin/zsh
# Takes the Mac App Store screenshots and the App Review screenshots of the folder permission flow.
#
#   packaging/screenshots/capture.sh            both sets
#   packaging/screenshots/capture.sh store      App Store screenshots only (no clicks needed)
#   packaging/screenshots/capture.sh review     App Review shots: you pick the two folders when asked
#
# Output: build/screenshots/store/*.png (1440x900, no alpha) and build/screenshots/review/*.png.
# Uses a demo library (make_demo_library.py) and the app's demo mode (MODELSHELF_DEMO), so nothing
# from your own cache, library or settings shows up or changes.
#
# Needs: Screen Recording permission for the app running this script (macOS asks on first use), and
# Model Shelf not running. The review shots run the sandboxed build, which must be signed with the same
# identity as any sandboxed Model Shelf you've run before (default: ThisBrainAI's Developer ID), or
# macOS asks whether the new build may use the old one's data.
set -euo pipefail
cd "${0:A:h}/../.."

WHICH="${1:-all}"
OUT="$PWD/build/screenshots"
DEMO="$PWD/build/demo"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: ThisBrainAI LLC (MP7PDLDJ96)}"
HERE=packaging/screenshots

if pgrep -x ModelShelf >/dev/null; then
  echo "Quit Model Shelf first: the demo runs its own copy." >&2
  exit 1
fi
mkdir -p "$OUT/store" "$OUT/review"
swiftc -O "$HERE/windows.swift" -o "$OUT/windows"

# build <dest.app> [SANDBOX=1]
build() {
  local dest=$1; shift
  env "$@" SIGN_IDENTITY="$IDENTITY" ./build-app.sh 2>&1 | tail -1
  rm -rf "$dest" && cp -R build/ModelShelf.app "$dest"
}

PID=""
launch() { # launch <app> <shot>
  MODELSHELF_DEMO="$DEMO" MODELSHELF_DEMO_SHOT=$2 "$1/Contents/MacOS/ModelShelf" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
  PID=$!
}
quit_app() {
  if [[ -n "$PID" ]]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  PID=""
}
# zsh skips EXIT traps when errexit fires, so also quit on errors.
trap quit_app EXIT
TRAPZERR() { quit_app }
TRAPINT() { quit_app; exit 130 }

windows() { "$OUT/windows" "$PID"; }
count() { windows | wc -l | tr -d ' '; }
wait_for() { # wait_for <op> <n> [seconds]: until the window count is >= n (op ge) or < n (op lt)
  local i=0 limit=$(( ${3:-15} * 4 ))
  while (( i++ < limit )); do
    local c=$(count)
    if [[ $1 == ge && $c -ge $2 ]] || [[ $1 == lt && $c -lt $2 ]]; then return 0; fi
    sleep 0.25
  done
  return 1
}

# shoot <out.png> [compose options]: captures every window of the app, back to front, and composes.
shoot() {
  local out=$1; shift
  local layers=() n=0
  mkdir -p "$OUT/layers"
  # The main window (the largest) first, then the others (the open panel). Capturing an alert that's
  # attached to the main window returns the main window with the alert in it, so a capture the same
  # size as the main window's is already covered and is skipped.
  local main_size=""
  for line in "${(@f)$(windows | sort -k4,4nr -k5,5nr)}"; do
    local f=(${=line})
    local png="$OUT/layers/$n.png"
    screencapture -x -o -l"${f[1]}" "$png"
    local size=$(sips -g pixelWidth -g pixelHeight "$png" | awk 'NR > 1 { printf "%s ", $2 }')
    if [[ -z "$main_size" ]]; then
      main_size=$size
    elif [[ "$size" == "$main_size" ]]; then
      continue
    fi
    layers+=("$png@${f[2]},${f[3]}")
    n=$((n + 1))
  done
  python3 "$HERE/compose.py" "$out" "$@" "${layers[@]}"
  rm -rf "$OUT/layers"
}

store() {
  build "$OUT/ModelShelf-demo.app"
  local scenario="" shot n=1
  for shot in library moving attention redownload activity; do
    local want=tidy; [[ $shot == attention || $shot == redownload ]] && want=attention
    if [[ $want != $scenario ]]; then python3 "$HERE/make_demo_library.py" --scenario $want >/dev/null; scenario=$want; fi
    launch "$OUT/ModelShelf-demo.app" $shot
    wait_for ge $([[ $shot == redownload ]] && echo 2 || echo 1)
    sleep 2.5 # window sizing, scan, row animations
    shoot "$OUT/store/$n-$shot.png" --size 1440x900
    quit_app
    n=$((n + 1))
  done
}

review() {
  python3 "$HERE/make_demo_library.py" --scenario tidy >/dev/null
  build "$OUT/ModelShelf-sandboxed.app" SANDBOX=1
  echo "Wait: Model Shelf is opening. Don't click anything yet."
  launch "$OUT/ModelShelf-sandboxed.app" setup
  wait_for ge 1 || { echo "Model Shelf didn't open a window." >&2; exit 1; }
  sleep 1.5
  shoot "$OUT/review/1-folder-setup.png" --plain

  # pick <n> <label> <file stem>: you open a folder picker and click Choose; we shoot both states.
  pick() {
    echo
    echo ">>> NOW: in Model Shelf, click Choose… next to \"$2\"."
    echo "    The picker opens in a demo folder. Don't change folders; just click Choose."
    wait_for ge 2 600 || { echo "No folder picker opened." >&2; exit 1; }
    sleep 1.5
    shoot "$OUT/review/$1-choose-$3-folder.png" --plain --redact-sidebar
    wait_for lt 2 600 || { echo "Timed out waiting for Choose." >&2; exit 1; }
    echo "    Got it."
    sleep 1
  }
  pick 2 "Hugging Face cache" cache
  shoot "$OUT/review/3-cache-folder-granted.png" --plain
  pick 4 "Model library" library
  shoot "$OUT/review/5-both-folders-granted.png" --plain
  quit_app
}

case $WHICH in
  store) store ;;
  review) review ;;
  all) store; review ;;
  *) echo "usage: $0 [store|review|all]" >&2; exit 2 ;;
esac
echo "Screenshots in $OUT/store and $OUT/review"

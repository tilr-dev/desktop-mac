#!/bin/sh
# Build Tilr.app and start it. Arguments go to the app:
#   --test                   a separate test instance, never the user's: config folder
#                            ~/.config/tilr-test (or TILR_CONFIG), so its own config.yml, control
#                            socket, web storage, pid file and window ("… · tilr-test"); made on the
#                            first run with window: { mode: window, inset: { x: 300, y: 200 },
#                            activate_at_launch: false } (it never takes the focus).
#                            Stops only a previous test instance (its tilr.pid). Drive it with
#                            tilr ctl --socket ~/.config/tilr-test/control.sock … or TILR_CONTROL=….
#   --probe                  check the page, the header, the fullscreen frame and a Space move, then quit
#                            (with --test: in the test instance)
#   --probe --snapshot PATH  also write PATH-menu-{left,right}.png of the page's top corners
#   --site DIR               show DIR instead of the config's site:/apps: (default ~/tilr)
#   --url URL                show a dev server instead (or TILR_URL), e.g. http://127.0.0.1:7891/
# Without --test it restarts the user's instance (config ~/.config/tilr, or TILR_CONFIG): stops the
# Tilr in that folder's tilr.pid (no pid file: every Tilr started without --config), never a test one.
# The page's TypeScript lives in the web repo (../../web); `npm run dev:site` there builds it and
# installs into the site folder this app serves (~/tilr unless `site:` in the config folder's
# config.yml or --site says otherwise; with `apps:` every app has a folder of its own). Both paths are printed below.
# A real bundle with a bundle id is what lets the Dock remember "Assign To → This Desktop".
set -eu
cd "$(dirname "$0")"

# --test is ours; the rest goes to the app.
testing=
for arg in "$@"; do
  shift
  if [ "$arg" = "--test" ]; then testing=1; else set -- "$@" "$arg"; fi
done
if [ -n "$testing" ]; then
  cfg=${TILR_CONFIG:-~/.config/tilr-test}
else
  cfg=${TILR_CONFIG:-~/.config/tilr}
fi
case $cfg in "~"|"~/"*) cfg=$HOME${cfg#"~"} ;; esac
if [ -n "$testing" ] && [ ! -f "$cfg/config.yml" ]; then
  mkdir -p "$cfg"
  printf '%s\n' '# Tilr test instance (./run.sh --test). Every key and its default: default.yml.' \
    'window: { mode: window, inset: { x: 300, y: 200 }, activate_at_launch: false }' > "$cfg/config.yml"
fi

# The site folder, the way Site.swift picks it: --site DIR, else site: in the config, else ~/tilr.
site=
prev=
for arg in "$@"; do
  [ "$prev" = "--site" ] && site=$arg
  prev=$arg
done
if [ -z "$site" ] && [ -f "$cfg/config.yml" ]; then
  if grep -q '^apps:' "$cfg/config.yml"; then
    site="one per app, see apps: in $cfg/config.yml"
  else
    site=$(sed -n 's/^site:[[:space:]]*//p' "$cfg/config.yml" | head -1)
  fi
fi
site=${site:-~/tilr}
case $site in "~"|"~/"*) site=$HOME${site#"~"} ;; esac
echo "web sources: $(cd ../../web 2>/dev/null && pwd)/src   (npm run dev:site there)"
echo "site folder: $site"
echo "config:      $cfg"

swift build -c release
app=build/Tilr.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# A new file, not a copy over the old one: the kernel caches a bundle's code signature by inode,
# and a binary overwritten in place is killed at launch from the Dock ("Code Signature Invalid").
rm -f "$app/Contents/MacOS/Tilr"
cp .build/release/Tilr "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/"
rm -rf "$app/Contents/Resources/web"
cp placeholder.html "$app/Contents/Resources/"
codesign --force --sign - "$app" 2>/dev/null || true
# One Tilr per config folder: the one running holds that folder's control socket and window.
# Stops the instance in $cfg/tilr.pid when that pid is a Tilr of this folder (one started with
# --config, for a test folder; one without, for the user's), and waits for it to go.
is_ours() {  # pid
  case $(ps -c -p "$1" -o comm= 2>/dev/null) in Tilr) ;; *) return 1 ;; esac
  args=$(ps -p "$1" -o args= 2>/dev/null)
  if [ -n "$testing" ]; then
    case $args in *"--config $cfg"*) return 0 ;; *) return 1 ;; esac
  else
    case $args in *"--config "*) return 1 ;; *) return 0 ;; esac
  fi
}
stop() {  # pid
  kill "$1" 2>/dev/null || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$1" 2>/dev/null || return 0; sleep 0.3; done
  kill -9 "$1" 2>/dev/null || true
}
if [ -f "$cfg/tilr.pid" ]; then
  pid=$(cat "$cfg/tilr.pid")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && is_ours "$pid"; then stop "$pid"; fi
elif [ -z "$testing" ]; then
  # No pid file yet (a Tilr from before they existed): every Tilr started without --config.
  for pid in $(pgrep -x Tilr || true); do is_ours "$pid" && stop "$pid"; done
fi

if [ -n "$testing" ]; then
  sock=$cfg/control.sock
  case $sock in "$HOME"/*) sock="~${sock#"$HOME"}" ;; esac
  echo "test instance: $cfg"
  echo "  tilr ctl --socket $sock apps"
  echo "  export TILR_CONTROL=$sock"
  set -- --config "$cfg" "$@"
fi

# Run the binary directly so stdout stays in this terminal.
exec "$app/Contents/MacOS/Tilr" "$@"

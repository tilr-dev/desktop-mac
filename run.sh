#!/bin/sh
# Build Tilr.app and start it. Arguments go to the app:
#   --test                   a separate test instance, never the user's: config folder
#                            ~/Library/Application Support/dev.tilr.mac.test (or TILR_CONFIG), so its own config.yml, control
#                            socket, web storage, pid file and window ("… · tilr-test"); made on the
#                            first run with window: { mode: window, inset: { x: 300, y: 200 },
#                            activate_at_launch: false } (it never takes the focus).
#                            Stops only a previous test instance (its tilr.pid). Drive it with
#                            tilr ctl --socket ~/Library/Application Support/dev.tilr.mac.test/control.sock … or TILR_CONTROL=….
#   --probe                  check the page, the header, the fullscreen frame and a Space move, then quit
#                            (with --test: in the test instance)
#   --probe --snapshot PATH  also write PATH-menu-{left,right}.png of the page's top corners
#   --site DIR               show DIR instead of the config's site:/apps: (default <config>/apps/default)
#   --url URL                show a dev server instead (or TILR_URL), e.g. http://127.0.0.1:7891/
# Without --test it restarts the user's instance (config ~/Library/Application Support/dev.tilr.mac, or TILR_CONFIG): stops the
# Tilr recorded in that folder's tilr.pid; no pid file means no process is stopped.
# The page's TypeScript lives in the web repo (../../web); `npm run dev:site` there builds it and
# installs into the site folder this app serves (<config>/apps/default unless `site:` in the config folder's
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
  cfg=${TILR_CONFIG:-"$HOME/Library/Application Support/dev.tilr.mac.test"}
else
  cfg=${TILR_CONFIG:-"$HOME/Library/Application Support/dev.tilr.mac"}
fi
# Explicit --config takes precedence for both the launcher and the app.
prev=
for arg in "$@"; do
  [ "$prev" = "--config" ] && cfg=$arg
  prev=$arg
done
[ "$prev" != "--config" ] || { echo '--config needs a folder' >&2; exit 1; }
case $cfg in "~"|"~/"*) cfg=$HOME${cfg#"~"} ;; esac
case $cfg in /*) ;; *) cfg="$PWD/$cfg" ;; esac
if [ -n "$testing" ] && [ ! -f "$cfg/config.yml" ]; then
  mkdir -p "$cfg"
  printf '%s\n' '# Tilr test instance (./run.sh --test). Every key and its default: default.yml.' \
    'window: { mode: window, inset: { x: 300, y: 200 }, activate_at_launch: false }' > "$cfg/config.yml"
fi

# The site folder, the way Site.swift picks it: --site DIR, else site: in the config, else <config>/apps/default.
site=
explicit_site=
prev=
for arg in "$@"; do
  if [ "$prev" = "--site" ]; then site=$arg; explicit_site=1; fi
  prev=$arg
done
if [ -z "$site" ] && [ -f "$cfg/config.yml" ]; then
  if grep -q '^apps:' "$cfg/config.yml"; then
    site="one per app, see apps: in $cfg/config.yml"
  else
    site=$(sed -n 's/^site:[[:space:]]*//p' "$cfg/config.yml" | head -1)
  fi
fi
# Config-relative site paths; command-line --site remains working-directory-relative.
if [ -n "$site" ] && [ -z "$explicit_site" ]; then
  case $site in /*|"~"|"~/"*|"one per app,"*) ;; *) site="$cfg/$site" ;; esac
fi
site=${site:-"$cfg/apps/default"}
case $site in "~"|"~/"*) site=$HOME${site#"~"} ;; esac
echo "web sources: $(cd ../../web 2>/dev/null && pwd)/src   (npm run dev:site there)"
echo "site folder: $site"
echo "config:      $cfg"

swift build --build-system native -c release
app=build/Tilr.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# A new file, not a copy over the old one: the kernel caches a bundle's code signature by inode,
# and a binary overwritten in place is killed at launch from the Dock ("Code Signature Invalid").
rm -f "$app/Contents/MacOS/Tilr"
cp .build/release/Tilr "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/"
# Dock's "Assign To" is keyed by bundle id, not --config. Isolate test windows
# from the user's All Desktops / desktop assignment as well as their data.
if [ -n "$testing" ]; then
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist)
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${bundle_id}.test" "$app/Contents/Info.plist"
fi
mkdir -p "$app/Contents/Frameworks"
rm -rf "$app/Contents/Frameworks/Sparkle.framework"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$app/Contents/Resources/web"
cp placeholder.html "$app/Contents/Resources/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
python3 ../../native-plugins/scripts/plugin.py build --output "$app/Contents/PlugIns"
codesign --force --sign - --entitlements Tilr.entitlements "$app"
# One Tilr per config folder: the one running holds that folder's control socket and window.
# Stops the instance in $cfg/tilr.pid when that pid is a Tilr of this folder (one started with
# --config, for a test folder; one without, for the user's), and waits for it to go.
is_ours() {  # pid
  case $(ps -c -p "$1" -o comm= 2>/dev/null) in Tilr) ;; *) return 1 ;; esac
  args=$(ps -p "$1" -o args= 2>/dev/null)
  case $args in
    *"--config $cfg"*) return 0 ;;
    *"--config "*) return 1 ;;
    *) [ -z "$testing" ] && [ "$cfg" = "$HOME/Library/Application Support/dev.tilr.mac" ] ;;
  esac
}
stop() {  # pid
  kill "$1" 2>/dev/null || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$1" 2>/dev/null || return 0; sleep 0.3; done
  kill -9 "$1" 2>/dev/null || true
}
if [ -f "$cfg/tilr.pid" ]; then
  pid=$(cat "$cfg/tilr.pid")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && is_ours "$pid"; then stop "$pid"; fi
fi

if [ -n "$testing" ]; then
  sock=$cfg/control.sock
  case $sock in "$HOME"/*) sock="~${sock#"$HOME"}" ;; esac
  echo "test instance: $cfg"
  echo "  tilr ctl --socket \"$sock\" apps"
  echo "  export TILR_CONTROL=\"$sock\""
fi

# Run the binary directly so stdout stays in this terminal.
exec "$app/Contents/MacOS/Tilr" --config "$cfg" "$@"

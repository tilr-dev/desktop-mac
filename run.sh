#!/bin/sh
# Build Tilr.app and start it. Arguments go to the app:
#   --probe                  check the page, the header, the fullscreen frame and a Space move, then quit
#   --probe --snapshot PATH  also write PATH-menu-{left,right}.png of the page's top corners
#   --site DIR               show DIR instead of the config's site:/apps: (default ~/tilr)
#   --url URL                show a dev server instead (or TILR_URL), e.g. http://127.0.0.1:7891/
# The page's TypeScript lives in the web repo (../../web); `npm run dev:site` there builds it and
# installs into the site folder this app serves (~/tilr unless `site:` in ~/.config/tilr/config.yml
# or --site says otherwise; with `apps:` every app has a folder of its own). Both paths are printed below.
# A real bundle with a bundle id is what lets the Dock remember "Assign To → This Desktop".
set -eu
cd "$(dirname "$0")"

# The site folder, the way Site.swift picks it: --site DIR, else site: in the config, else ~/tilr.
site=
prev=
for arg in "$@"; do
  [ "$prev" = "--site" ] && site=$arg
  prev=$arg
done
if [ -z "$site" ] && [ -f ~/.config/tilr/config.yml ]; then
  if grep -q '^apps:' ~/.config/tilr/config.yml; then
    site="one per app, see apps: in ~/.config/tilr/config.yml"
  else
    site=$(sed -n 's/^site:[[:space:]]*//p' ~/.config/tilr/config.yml | head -1)
  fi
fi
site=${site:-~/tilr}
case $site in "~"|"~/"*) site=$HOME${site#"~"} ;; esac
echo "web sources: $(cd ../../web 2>/dev/null && pwd)/src   (npm run dev:site there)"
echo "site folder: $site"

swift build -c release
app=build/Tilr.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Tilr "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/"
rm -rf "$app/Contents/Resources/web"
cp placeholder.html "$app/Contents/Resources/"

# Run the binary directly so stdout stays in this terminal.
exec "$app/Contents/MacOS/Tilr" "$@"

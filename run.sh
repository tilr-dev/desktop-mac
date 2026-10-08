#!/bin/sh
# Build Tilr.app and start it. Arguments go to the app:
#   --probe                  check the page, the header, the fullscreen frame and a Space move, then quit
#   --probe --snapshot PATH  also write PATH-menu-{left,right}.png of the page's top corners
#   --site DIR               show DIR instead of ~/tilr-mac
#   --url URL                show a dev server instead (or TILR_URL), e.g. http://127.0.0.1:7891/
# A real bundle with a bundle id is what lets the Dock remember "Assign To → This Desktop".
set -eu
cd "$(dirname "$0")"

swift build -c release
app=build/Tilr.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Tilr "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/"
rm -rf "$app/Contents/Resources/web"
cp -R web "$app/Contents/Resources/web"

# Run the binary directly so stdout stays in this terminal.
exec "$app/Contents/MacOS/Tilr" "$@"

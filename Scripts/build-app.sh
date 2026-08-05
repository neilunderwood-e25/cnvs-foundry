#!/bin/zsh

set -euo pipefail

configuration="${1:-debug}"
run_after_build="${2:-}"

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    echo "Usage: $0 [debug|release] [--run]" >&2
    exit 2
fi

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

swift build -c "$configuration"
binary_directory="$(swift build -c "$configuration" --show-bin-path)"
app_path="$binary_directory/Canvas Foundry.app"
contents_path="$app_path/Contents"

if [[ "$run_after_build" == "--run" ]]; then
    # `open` activates an existing process with this bundle identifier instead
    # of loading the newly-built executable. Quit the prior development instance
    # before replacing its bundle so every --run actually runs current code.
    # AppleScript quit can block forever while a modal alert is open, so target
    # only this checkout's development executable and keep the wait bounded.
    running_pids=($(pgrep -f "$app_path/Contents/MacOS/CanvasFoundry" || true))
    for foundry_pid in $running_pids; do
        /bin/kill -TERM "$foundry_pid" 2>/dev/null || true
    done
    for _ in {1..50}; do
        remaining_pid="$(pgrep -f "$app_path/Contents/MacOS/CanvasFoundry" | head -1 || true)"
        [[ -z "$remaining_pid" ]] && break
        /bin/sleep 0.1
    done
    if [[ -n "${remaining_pid:-}" ]]; then
        /bin/kill -KILL "$remaining_pid" 2>/dev/null || true
    fi
fi

# This target is intentionally exact and lives inside SwiftPM's build output.
# Rebuilding the development bundle must not touch installed applications.
if [[ -d "$app_path" ]]; then
    /bin/rm -rf "$app_path"
fi

/bin/mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
/bin/cp "Sources/CanvasFoundry/Resources/AppInfo.plist" "$contents_path/Info.plist"
/bin/cp "$binary_directory/CanvasFoundry" "$contents_path/MacOS/CanvasFoundry"

# SwiftPM's generated Bundle.module accessor retains the matching absolute
# build-product path, so this development bundle deliberately remains tied to
# this checkout. A distributable archive will use an Xcode app target, which
# embeds resource bundles in the conventional Contents/Resources location.

/usr/bin/codesign --force --deep --sign - "$app_path"

# Apps built into SwiftPM's hidden `.build` directory are not always indexed by
# Launch Services. Register explicitly so macOS privacy settings and `tccutil`
# can resolve the bundle identifier before the first microphone request.
launch_services_register="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$launch_services_register" -f "$app_path"

echo "$app_path"
if [[ "$run_after_build" == "--run" ]]; then
    /usr/bin/open "$app_path"
fi

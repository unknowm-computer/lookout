#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Build first so the image always contains the current source and update settings.
bash scripts/build.sh
task_app_dir="$PWD/build/Lookout.app"
task_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_app_dir/Contents/Info.plist")
if [[ ! "$task_version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "Invalid app version for DMG filename: $task_version" >&2
    exit 1
fi

task_temp_dir=$(mktemp -d "$PWD/build/dmg.XXXXXX")
trap 'rm -rf "$task_temp_dir"' EXIT
task_stage_dir="$task_temp_dir/contents"
task_output="$PWD/build/Lookout-$task_version.dmg"
mkdir -p "$task_stage_dir"
ditto "$task_app_dir" "$task_stage_dir/Lookout.app"
ln -s /Applications "$task_stage_dir/Applications"
cp "scripts/Install Lookout.command" "$task_stage_dir/Install Lookout.command"
chmod 755 "$task_stage_dir/Install Lookout.command"
cp "Resources/Install Help.txt" "$task_stage_dir/설치 안내.txt"
codesign --verify --deep --strict "$task_stage_dir/Lookout.app"

# HFS+ / UDZO images can be opened on the minimum supported macOS 15 as well.
hdiutil create -volname Lookout -srcfolder "$task_stage_dir" -fs HFS+ \
    -format UDZO "$task_temp_dir/Lookout.dmg"
hdiutil verify "$task_temp_dir/Lookout.dmg"
mv -f "$task_temp_dir/Lookout.dmg" "$task_output"
printf 'Created %s\n' "$task_output"

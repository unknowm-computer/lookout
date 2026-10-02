#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
mkdir -p build
task_info_plist=$(mktemp "$PWD/build/Lookout-info.XXXXXX")
trap 'rm -f "$task_info_plist"' EXIT
python3 scripts/configure-updates.py Resources/Info.plist "$task_info_plist"

task_verify_universal() {
    local task_binary="$1"
    local task_arch
    for task_arch in arm64 x86_64; do
        xcrun lipo "$task_binary" -verify_arch "$task_arch"
    done
}

task_swift_build_args=(-c release --arch arm64 --arch x86_64 --disable-sandbox
    --cache-path .build/cache --config-path .build/config --security-path .build/security)
xcrun swift build "${task_swift_build_args[@]}"

task_bin_dir=$(xcrun swift build "${task_swift_build_args[@]}" --show-bin-path)
task_verify_universal "$task_bin_dir/Lookout"
task_app_dir="$PWD/build/Lookout.app"
mkdir -p "$task_app_dir/Contents/MacOS" "$task_app_dir/Contents/Resources"
cp "$task_bin_dir/Lookout" "$task_app_dir/Contents/MacOS/Lookout.new"
mv -f "$task_app_dir/Contents/MacOS/Lookout.new" "$task_app_dir/Contents/MacOS/Lookout"
cp "$task_info_plist" "$task_app_dir/Contents/Info.plist"
cp Resources/Sparkle-LICENSE.txt "$task_app_dir/Contents/Resources/Sparkle-LICENSE.txt"
task_sparkle_framework="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$task_sparkle_framework" ]; then
    echo "Sparkle.framework is missing from the resolved package artifacts." >&2
    exit 1
fi
while IFS= read -r -d '' task_framework_file; do
    case "$(file -b "$task_framework_file")" in
        Mach-O*) task_verify_universal "$task_framework_file" ;;
    esac
done < <(find "$task_sparkle_framework" -type f -print0)
mkdir -p "$task_app_dir/Contents/Frameworks"
ditto "$task_sparkle_framework" "$task_app_dir/Contents/Frameworks/Sparkle.framework"
xcrun swift -module-cache-path "$PWD/.build/module-cache" scripts/GenerateIcon.swift "$PWD/build/AppIcon.iconset"
iconutil -c icns build/AppIcon.iconset -o "$task_app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$task_app_dir"
codesign --verify --deep --strict "$task_app_dir"
printf 'Built Universal (arm64 + x86_64) %s\n' "$task_app_dir"

#!/bin/bash
set -euo pipefail

# Distributed next to Lookout.app in the DMG; requires no Xcode or developer account.
task_script_dir=$(cd "$(dirname "$0")" && pwd -P)
task_source="$task_script_dir/Lookout.app"
task_install_dir=/Applications
task_launch=true
while [ "$#" -gt 0 ]; do
    case "$1" in
        --user) task_install_dir="$HOME/Applications"; shift ;;
        --destination)
            [ "$#" -ge 2 ] || { echo '--destination 뒤에 설치 폴더를 지정하세요.' >&2; exit 1; }
            task_install_dir="$2"; shift 2 ;;
        --no-launch) task_launch=false; shift ;;
        *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    esac
done
case "$task_install_dir" in
    /*) ;;
    *) echo '설치 폴더는 절대 경로로 지정하세요.' >&2; exit 1 ;;
esac

task_bundle_id=local.lookout.app
task_check_app() {
    local task_app="$1"
    [ -d "$task_app" ] && [ ! -L "$task_app" ] || {
        echo "앱 폴더를 확인할 수 없습니다: $task_app" >&2; return 1;
    }
    local task_identifier
    task_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$task_app/Contents/Info.plist")
    [ "$task_identifier" = "$task_bundle_id" ] || {
        echo 'Lookout과 Bundle ID가 다른 앱은 설치하거나 교체하지 않습니다.' >&2; return 1;
    }
}
task_check_app "$task_source"
/usr/bin/codesign --verify --deep --strict "$task_source"
task_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_source/Contents/Info.plist")

if ! /bin/mkdir -p "$task_install_dir"; then
    echo '설치 폴더에 접근할 수 없습니다. --user 옵션으로 사용자 Applications에 설치할 수 있습니다.' >&2
    exit 1
fi
task_install_dir=$(cd "$task_install_dir" && pwd -P)
task_target="$task_install_dir/Lookout.app"
if [ ! -w "$task_install_dir" ]; then
    echo '설치 폴더에 쓰기 권한이 없습니다. --user 옵션으로 사용자 Applications에 설치할 수 있습니다.' >&2
    exit 1
fi
if [ "$task_source" = "$task_target" ]; then
    echo 'DMG 안의 설치 스크립트를 실행하세요. 원본 앱과 설치 위치가 같습니다.' >&2
    exit 1
fi
if [ -e "$task_target" ] || [ -L "$task_target" ]; then task_check_app "$task_target"; fi

task_lock="$task_install_dir/.Lookout-install.lock"
if ! /bin/mkdir "$task_lock" 2>/dev/null; then
    echo "다른 설치가 진행 중이거나 이전 설치가 중단되었습니다: $task_lock" >&2
    exit 1
fi
task_temp=''
task_previous_saved=false
task_installed=false
task_success=false
task_cleanup() {
    local task_status=$?
    trap - EXIT INT TERM HUP
    if ! $task_success && $task_previous_saved; then
        if $task_installed; then /bin/rm -rf "$task_target"; fi
        if ! /bin/mv "$task_temp/Previous Lookout.app" "$task_target"; then
            echo "기존 앱 복구에 실패했습니다. 백업을 보존합니다: $task_temp/Previous Lookout.app" >&2
            /bin/rmdir "$task_lock" || true
            exit 1
        fi
        echo '설치를 완료하지 못해 기존 Lookout을 복구했습니다.' >&2
    fi
    if [ -n "$task_temp" ]; then /bin/rm -rf "$task_temp"; fi
    /bin/rmdir "$task_lock" || true
    exit "$task_status"
}
trap task_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
task_temp=$(/usr/bin/mktemp -d "$task_install_dir/.Lookout-install.XXXXXX")
task_staged_app="$task_temp/Lookout.app"

printf 'Lookout %s 설치 준비 중…\n' "$task_version"
/usr/bin/ditto "$task_source" "$task_staged_app"
/usr/bin/codesign --verify --deep --strict "$task_staged_app"
# Remove only this attribute from the new app copy. Do not change the DMG, source,
# preferences, other apps, Gatekeeper policy, or any other extended attributes.
/usr/bin/xattr -dr com.apple.quarantine "$task_staged_app"
/usr/bin/codesign --verify --deep --strict "$task_staged_app"

# Stop only the current user's executable at the exact destination being replaced.
# Never stop development builds, other copies, or unrelated namesakes.
task_process_is_target() {
    local task_executable task_executable_dir
    task_executable=$(/bin/ps -p "$1" -o comm= || true)
    case "$task_executable" in */Lookout) ;; *) return 1 ;; esac
    task_executable_dir=$(cd "$(dirname "$task_executable")" 2>/dev/null && pwd -P) || return 1
    [ "$task_executable_dir/Lookout" = "$task_target/Contents/MacOS/Lookout" ]
}
for task_pid in $(/usr/bin/pgrep -u "$(/usr/bin/id -u)" -x Lookout || true); do
    if task_process_is_target "$task_pid"; then
        echo '설치 위치의 실행 중인 Lookout을 종료합니다…'
        kill -TERM "$task_pid" 2>/dev/null || true
        for ((task_attempt = 0; task_attempt < 50; task_attempt++)); do
            task_process_is_target "$task_pid" || break
            /bin/sleep 0.1
        done
        if task_process_is_target "$task_pid"; then
            echo 'Lookout을 종료하지 못했습니다. 앱을 직접 종료한 뒤 다시 설치하세요.' >&2
            exit 1
        fi
    fi
done

if [ -e "$task_target" ] || [ -L "$task_target" ]; then
    task_check_app "$task_target"
    /bin/mv "$task_target" "$task_temp/Previous Lookout.app"
    task_previous_saved=true
fi
/bin/mv "$task_staged_app" "$task_target"
task_installed=true
/usr/bin/codesign --verify --deep --strict "$task_target"
task_success=true
printf '설치 완료: %s\n기존 설정은 유지됩니다.\n' "$task_target"
if $task_launch; then
    if ! /usr/bin/open "$task_target"; then
        echo '앱은 설치됐지만 실행하지 못했습니다. 설치 위치에서 Lookout을 직접 실행하세요.' >&2
    fi
fi

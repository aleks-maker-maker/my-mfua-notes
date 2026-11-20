#!/usr/bin/env bash
set -euo pipefail

source_url=https://github.com/rurewa/imfua.git
destination=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
source_default=$(dirname "$destination")/imfua-sync-source
source_path=${1:-$source_default}

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

if (( $# > 1 )); then
    fail 'Usage: bash sync/sync.sh [source-path]'
fi
[[ -d "$destination/.git" ]] || fail 'The destination must be its own Git repository.'

# Resolve the existing parent first, including when the clone does not exist yet.
source_parent=$(cd "$(dirname "$source_path")" && pwd -P)
source_path=$source_parent/$(basename "$source_path")
if [[ -e "$source_path" ]]; then
    source_path=$(cd "$source_path" && pwd -P)
fi

destination_check=$destination
source_check=$source_path
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        destination_check=${destination_check,,}
        source_check=${source_check,,}
        ;;
esac
if [[ "$source_check/" == "$destination_check/"* || "$destination_check/" == "$source_check/"* ]]; then
    fail 'Use separate source and destination directories.'
fi

if [[ ! -e "$source_path" ]]; then
    git clone --branch main --single-branch --config core.autocrlf=false "$source_url" "$source_path"
fi
[[ -d "$source_path/.git" ]] || fail 'The source must be a dedicated clone.'
[[ "$(git -C "$source_path" remote get-url origin)" == "$source_url" ]] || fail 'Unexpected source origin.'
[[ "$(git -C "$source_path" branch --show-current)" == main ]] || fail 'The source must be on main.'
[[ -z "$(git -C "$source_path" status --porcelain --untracked-files=no)" ]] || fail 'The source has local changes.'

git -C "$source_path" pull --ff-only origin main
revision=$(git -C "$source_path" rev-parse HEAD)
[[ "$revision" == "$(git -C "$source_path" rev-parse refs/remotes/origin/main)" ]] || fail 'The source contains local commits.'

reserved=$(git -C "$source_path" ls-tree --name-only HEAD)
if grep -Eiq '^(sync|\.git)$' <<< "$reserved"; then
    fail 'The source uses a path reserved in the destination.'
fi
tree=$(git -C "$source_path" ls-tree -r HEAD)
if grep -Eq '^(120000|160000) ' <<< "$tree"; then
    fail 'The source includes symbolic links or submodules.'
fi
link=$(find "$destination" -path "$destination/.git" -prune -o -path "$destination/sync" -prune -o -type l -print -quit)
[[ -z "$link" ]] || fail "Destination contains a symbolic link: $link"

archive=$(mktemp)
trap 'rm -f -- "$archive"' EXIT
git -C "$source_path" archive --format=tar --output="$archive" HEAD
tar -xf "$archive" -C "$destination"
printf 'Source commit: %s\nDestination: %s\n' "$revision" "$destination"

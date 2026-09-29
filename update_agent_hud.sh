#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
vendor="$root/Vendor/AgentHUDOpen"
source_repo=${1:-https://github.com/jazzenchen/agent-hud-open.git}
tmp=$(mktemp -d)
next=$(mktemp -d "$vendor/.update.XXXXXX")

cleanup() {
    if [[ ! -d "$vendor/Sources" && -d "$next/previous" ]]; then
        mv "$next/previous" "$vendor/Sources"
    fi
    rm -rf "$tmp" "$next"
}
trap cleanup EXIT

git clone --quiet --no-hardlinks "$source_repo" "$tmp/upstream"
revision=$(git -C "$tmp/upstream" rev-parse HEAD)
pinned=$(cat "$vendor/UPSTREAM_REVISION")
git -C "$tmp/upstream" worktree add --quiet --detach "$tmp/baseline" "$pinned"
git -C "$tmp/baseline" apply --3way "$vendor/boringnotch.patch"
rm -rf "$tmp/baseline/Sources/AgentHUDOpenApp"
if ! diff -qr "$vendor/Sources" "$tmp/baseline/Sources" > "$tmp/local-diff"; then
    echo "Agent HUD sources differ from pinned upstream plus Boring Notch patch:" >&2
    cat "$tmp/local-diff" >&2
    exit 1
fi
git -C "$tmp/upstream" apply --3way --check "$vendor/boringnotch.patch"
git -C "$tmp/upstream" apply --3way "$vendor/boringnotch.patch"

mkdir -p "$tmp/package/Sources"
cp "$vendor/Package.swift" "$tmp/package/"
cp "$tmp/upstream/LICENSE" "$tmp/upstream/THIRD_PARTY_NOTICES.txt" "$tmp/package/"
for target in AgentHUDSupport AgentHUDCore AgentHUDDesktop; do
    cp -R "$tmp/upstream/Sources/$target" "$tmp/package/Sources/"
done
XDG_CACHE_HOME="$tmp/cache" CLANG_MODULE_CACHE_PATH="$tmp/clang-cache" \
    swift build --disable-sandbox --package-path "$tmp/package" \
        --cache-path "$tmp/cache" --scratch-path "$tmp/build"

cp -R "$tmp/package/Sources" "$next/"
mv "$vendor/Sources" "$next/previous"
mv "$next/Sources" "$vendor/Sources"
cp "$tmp/package/LICENSE" "$tmp/package/THIRD_PARTY_NOTICES.txt" "$vendor/"
printf '%s\n' "$revision" > "$vendor/UPSTREAM_REVISION"
rm -rf "$next/previous"
echo "Agent HUD updated to $revision. Build Boring Notch to verify the host integration."

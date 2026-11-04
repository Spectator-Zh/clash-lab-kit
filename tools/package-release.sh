#!/usr/bin/env bash
# Build architecture-specific archives from a committed Git tree.
set -euo pipefail
if [ "$#" -ne 3 ]; then
    printf '用法: bash tools/package-release.sh <正式提交> <版本号> <输出目录>\n' >&2
    exit 1
fi
revision=$(git rev-parse --verify "$1^{commit}")
version=$2
[[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf '版本号格式应为 vX.Y.Z\n' >&2; exit 1; }
mkdir -p -- "$3"
output=$(cd -- "$3" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
for arch in amd64 arm64; do
    mkdir -p "$tmp/$arch"
    git archive --format=tar --prefix=clash-lab-kit/ "$revision" | tar -xf - -C "$tmp/$arch"
    zip="$tmp/$arch/clash-lab-kit/resources/zip"
    if [ "$arch" = amd64 ]; then
        rm -f -- "$zip/mihomo-linux-arm64-v1.19.25.gz" "$zip/yq_linux_arm64.tar.gz" "$zip/subconverter_aarch64.tar.gz"
    else
        rm -f -- "$zip/mihomo-linux-amd64-compatible-v1.19.25.gz" "$zip/yq_linux_amd64.tar.gz" "$zip/subconverter_linux64.tar.gz"
    fi
    tar -czf "$output/clash-lab-kit-$version-linux-$arch.tar.gz" -C "$tmp/$arch" clash-lab-kit
done

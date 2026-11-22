#!/bin/bash
# Releases a den build of the fork: names the build den.N on main, tags it,
# builds the static Linux binaries den's image downloads, publishes them with
# SHA256SUMS on unsady/fx, and points den's Dockerfile at them.
#
#   scripts/den-release.sh <notes-file>
#
# N is one more than the current den_build. Run it on a clean main that holds
# everything the release ships. den's Dockerfile is left changed, not
# committed, for den's own branch.
set -euo pipefail

if (( $# != 1 )) || [[ ! -f $1 ]]; then
  echo 'Usage: scripts/den-release.sh <notes-file>' >&2
  exit 2
fi
notes=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")

cd "$(dirname "$0")/.."
dockerfile=../den/Dockerfile
[[ -f $dockerfile ]] || { echo "No den checkout at $dockerfile" >&2; exit 1; }
[[ $(git branch --show-current) == main ]] || { echo 'Not on main' >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo 'main is not clean' >&2; exit 1; }

version=$(sed -n 's/^pub const version = "\(.*\)";/\1/p' src/main.zig)
current=$(sed -n 's/^pub const den_build = "den\.\([0-9]*\)";/\1/p' src/main.zig)
[[ -n $version && -n $current ]] || { echo 'No version or den_build in src/main.zig' >&2; exit 1; }
build=den.$((current + 1))
tag=v$version-$build

sed -i '' "s/^pub const den_build = \"den\.$current\";/pub const den_build = \"$build\";/" src/main.zig
git commit -qm "Name this build $build" src/main.zig
git tag "$tag"

dist=$(mktemp -d)
trap 'rm -rf "$dist"' EXIT
for arch in aarch64 x86_64; do
  zig build -Doptimize=ReleaseSafe -Dtarget=$arch-linux-musl --prefix "$dist/$arch"
  cp "$dist/$arch/bin/fx" "$dist/fx-linux-$arch"
done
(cd "$dist" && shasum -a 256 fx-linux-aarch64 fx-linux-x86_64 > SHA256SUMS)

git push -q origin main "$tag"
gh release create "$tag" -R unsady/fx --title "$tag" --notes-file "$notes" \
  "$dist/fx-linux-aarch64" "$dist/fx-linux-x86_64" "$dist/SHA256SUMS"

sum() { awk -v f="fx-linux-$1" '$2 == f { print $1 }' "$dist/SHA256SUMS"; }
sed -i '' \
  -e "s/^ARG FX_VERSION=.*/ARG FX_VERSION=$tag/" \
  -e "s/^ARG FX_SHA256_AARCH64=.*/ARG FX_SHA256_AARCH64=$(sum aarch64)/" \
  -e "s/^ARG FX_SHA256_X86_64=.*/ARG FX_SHA256_X86_64=$(sum x86_64)/" \
  "$dockerfile"
echo "Released $tag; $dockerfile now uses it."

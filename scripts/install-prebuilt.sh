#!/bin/sh

# Install the arm64 macOS binary published with the matching GitHub tag.
# This script intentionally uses only tools included with macOS 13 or newer.
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
plugin_dir=$(dirname -- "$script_dir")
product=herdr-dopa-monitor
artifact="$product-macos-arm64.tar.gz"
checksum="$artifact.sha256"
repository=${HERDR_DOPA_RELEASE_REPOSITORY:-gw31415/herdr-dopa-monitor}

if [ "$(uname -s)" != Darwin ]; then
  printf 'error: %s supports macOS only\n' "$product" >&2
  exit 1
fi

macos_major=$(/usr/bin/sw_vers -productVersion | cut -d. -f1)
case $macos_major in
  ''|*[!0123456789]*)
    printf 'error: could not determine the macOS version\n' >&2
    exit 1
    ;;
esac
if [ "$macos_major" -lt 13 ]; then
  printf 'error: %s requires macOS 13 or newer\n' "$product" >&2
  exit 1
fi

if [ "$(uname -m)" != arm64 ]; then
  printf 'error: %s requires Apple Silicon (arm64)\n' "$product" >&2
  exit 1
fi

version=$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$plugin_dir/herdr-plugin.toml" | sed -n '1p')
if [ -z "$version" ]; then
  printf 'error: could not read plugin version from herdr-plugin.toml\n' >&2
  exit 1
fi

tag=${HERDR_DOPA_RELEASE_TAG:-v$version}
base_url=${HERDR_DOPA_RELEASE_BASE_URL:-https://github.com/$repository/releases/download/$tag}
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/herdr-dopa-monitor.XXXXXX")
temporary_output=
cleanup() {
  rm -rf "$temporary_dir"
  if [ -n "$temporary_output" ]; then
    rm -f "$temporary_output"
  fi
}
trap cleanup EXIT HUP INT TERM

download() {
  url=$1
  destination=$2
  curl --fail --location --silent --show-error \
    --retry 3 --retry-delay 1 \
    --proto '=https' --tlsv1.2 \
    --output "$destination" "$url"
}

fallback_to_source() {
  if [ "${HERDR_DOPA_ALLOW_SOURCE_FALLBACK:-1}" = 1 ] && \
      command -v swift >/dev/null 2>&1 && \
      [ -f "$plugin_dir/Package.swift" ]; then
    printf 'warning: prebuilt release is unavailable; building with the local Swift toolchain\n' >&2
    cleanup
    trap - EXIT HUP INT TERM
    exec sh "$script_dir/build.sh"
  fi

  printf 'error: prebuilt release is unavailable and a local Swift build cannot be used\n' >&2
  exit 1
}

printf 'Downloading %s (%s)\n' "$product" "$tag"
if ! download "$base_url/$artifact" "$temporary_dir/$artifact"; then
  fallback_to_source
fi
if ! download "$base_url/$checksum" "$temporary_dir/$checksum"; then
  fallback_to_source
fi

expected_hash=$(awk -v name="$artifact" \
  '$2 == name || $2 == "*" name { print $1; exit }' \
  "$temporary_dir/$checksum")
case $expected_hash in
  *[!0123456789abcdefABCDEF]*|'')
    printf 'error: release checksum is malformed\n' >&2
    exit 1
    ;;
esac
if [ "${#expected_hash}" -ne 64 ]; then
  printf 'error: release checksum is not SHA-256\n' >&2
  exit 1
fi

actual_hash=$(shasum -a 256 "$temporary_dir/$artifact" | awk '{print $1}')
if [ "$actual_hash" != "$expected_hash" ]; then
  printf 'error: checksum verification failed for %s\n' "$artifact" >&2
  exit 1
fi

archive_listing=$(tar -tzf "$temporary_dir/$artifact")
if [ "$archive_listing" != "$product" ]; then
  printf 'error: release archive has unexpected contents\n' >&2
  exit 1
fi
tar -xzf "$temporary_dir/$artifact" -C "$temporary_dir"

binary_description=$(/usr/bin/file "$temporary_dir/$product")
case $binary_description in
  *Mach-O*64-bit*arm64*) ;;
  *)
    printf 'error: release does not contain an arm64 Mach-O binary\n' >&2
    exit 1
    ;;
esac
if [ "$(/usr/bin/lipo -archs "$temporary_dir/$product")" != arm64 ]; then
  printf 'error: release binary must contain only the arm64 architecture\n' >&2
  exit 1
fi
if ! /usr/bin/codesign --verify --strict "$temporary_dir/$product"; then
  printf 'error: release binary has an invalid code signature\n' >&2
  exit 1
fi

mkdir -p "$plugin_dir/bin"
temporary_output="$plugin_dir/bin/.$product.tmp.$$"
install -m 755 "$temporary_dir/$product" "$temporary_output"
mv -f "$temporary_output" "$plugin_dir/bin/$product"
temporary_output=

printf 'Installed %s\n' "$plugin_dir/bin/$product"

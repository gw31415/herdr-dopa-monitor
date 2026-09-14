#!/bin/sh

# Build the native executable for local Apple Silicon development. Release
# packaging targets arm64 explicitly; see .github/workflows/release.yml.
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
plugin_dir=$(dirname -- "$script_dir")
product=herdr-dopa-monitor
output_dir="$plugin_dir/bin"

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  printf 'error: %s supports Apple Silicon macOS only\n' "$product" >&2
  exit 1
fi

swift build \
  --package-path "$plugin_dir" \
  --configuration release \
  --product "$product"

swift_bin_dir=$(swift build \
  --package-path "$plugin_dir" \
  --configuration release \
  --show-bin-path)

mkdir -p "$output_dir"
temporary_output="$output_dir/.$product.tmp.$$"
trap 'rm -f "$temporary_output"' EXIT HUP INT TERM

install -m 755 "$swift_bin_dir/$product" "$temporary_output"
mv -f "$temporary_output" "$output_dir/$product"
trap - EXIT HUP INT TERM

printf 'Built %s\n' "$output_dir/$product"

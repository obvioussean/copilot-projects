#!/usr/bin/env bash

# SwiftPM's native and Xcode build systems emit flat and macOS-style bundles.
bundle_resources() {
  local bundle="$1"
  if [ ! -d "$bundle" ]; then
    echo "error: missing resource bundle: $bundle" >&2
    return 1
  fi
  if [ -d "$bundle/Contents/Resources" ]; then
    printf '%s\n' "$bundle/Contents/Resources"
  else
    printf '%s\n' "$bundle"
  fi
}

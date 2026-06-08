#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source_app="$script_dir/macos/OpenCodeBench.app"
target_dir="$HOME/Applications"
target_app="$target_dir/OpenCodeBench.app"
target_support_dir="$HOME/.local/share/opencodebench"

if [[ ! -d "$source_app" ]]; then
  print -u2 "Error: source app bundle not found: $source_app"
  exit 1
fi

mkdir -p "$target_dir"
rm -rf "$target_app"
cp -R "$source_app" "$target_app"
chmod +x "$target_app/Contents/MacOS/OpenCodeBench"

mkdir -p "$target_support_dir"
cp "$script_dir/opencode-bench.sh" "$target_support_dir/opencode-bench.sh"
cp "$script_dir/hermes-bench.sh" "$target_support_dir/hermes-bench.sh"
cp "$script_dir/capture-task-start.sh" "$target_support_dir/capture-task-start.sh"
cp "$script_dir/capture-task-finish.sh" "$target_support_dir/capture-task-finish.sh"
chmod +x "$target_support_dir/opencode-bench.sh" "$target_support_dir/hermes-bench.sh" "$target_support_dir/capture-task-start.sh" "$target_support_dir/capture-task-finish.sh"

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$lsregister" ]]; then
  "$lsregister" -u "$source_app" >/dev/null 2>&1 || true
  "$lsregister" -f "$target_app" >/dev/null 2>&1 || true
fi

if command -v mdimport >/dev/null 2>&1; then
  mdimport "$target_app" >/dev/null 2>&1 || true
fi

print -r -- "Installed OpenCodeBench.app to $target_app"
print -r -- "Installed OpenCodeBench scripts to $target_support_dir"
print -r -- "Launch it from Spotlight, Raycast, Alfred, Finder, or with: open '$target_app'"

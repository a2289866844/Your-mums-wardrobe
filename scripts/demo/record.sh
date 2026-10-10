#!/bin/zsh
# Explicit invocation only. Record a reviewed screen rectangle, never the whole desktop by default.
set -eu
if [[ $# -lt 2 || $# -gt 3 ]]; then
  print -u2 'Usage: scripts/demo/record.sh x,y,width,height output.mp4 [seconds=15]'
  exit 2
fi
rect="$1"
output="$2"
seconds="${3:-15}"
if [[ ! "$rect" =~ '^[0-9]+,[0-9]+,[0-9]+,[0-9]+$' || ! "$seconds" =~ '^[0-9]+$' ]]; then
  print -u2 'Rectangle and duration must be positive numeric values.'
  exit 2
fi
if [[ "$output" != *.mp4 ]]; then
  print -u2 'Output must end in .mp4.'
  exit 2
fi
if [[ -e "$output" || -e "${output%.mp4}.mov" ]]; then
  print -u2 'Output already exists; choose a new filename.'
  exit 2
fi
ffmpeg_path="$(command -v ffmpeg)"
raw="${output%.mp4}.mov"
print "Recording only rectangle $rect for ${seconds}s. Native capture includes the cursor."
/usr/sbin/screencapture -v -V "$seconds" -R "$rect" "$raw"
"$ffmpeg_path" -hide_banner -loglevel error -i "$raw" -an -vf 'scale=trunc(iw/2)*2:trunc(ih/2)*2' -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -movflags +faststart "$output"
print "Saved $output (native original retained at $raw)"

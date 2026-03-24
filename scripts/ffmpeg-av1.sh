#!/bin/bash
# AV1 transcode (Intel VA-API 10-bit)
set -euo pipefail

SRC="/store/media/video/transcode"
DST="/store/media/video/transcode/av1"

find "$SRC" -path "$DST" -prune -o -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mts' -o -iname '*.m4v' -o -iname '*.mxf' \) -print0 | while IFS= read -r -d '' file; do
  rel="${file#$SRC/}"
  outdir="$DST/$(dirname "$rel")"
  [ "$outdir" = "$DST/." ] && outdir="$DST"
  outfile="$outdir/$(basename "${rel%.*}").mp4"

  [ -f "$outfile" ] && { echo "SKIP: $rel"; continue; }
  mkdir -p "$outdir"
  chown st:st "$outdir"

  echo "=== $rel ==="

  # Try full hardware path first, fall back to software decode for 4:2:2
  if ! ffmpeg -nostdin -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi \
    -i "$file" \
    -c:v av1_vaapi -g 240 \
    -c:a aac -b:a 256k -ac 2 \
    -map 0:v:0 -map '0:a?' \
    -map_metadata 0 -movflags +use_metadata_tags+faststart \
    "$outfile" 2>&1; then
    echo "--- retrying with software decode ---"
    rm -f "$outfile"
    ffmpeg -nostdin -vaapi_device /dev/dri/renderD128 \
      -i "$file" \
      -vf 'format=p010le,hwupload' \
      -c:v av1_vaapi -g 240 \
      -c:a aac -b:a 256k -ac 2 \
      -map 0:v:0 -map '0:a?' \
      -map_metadata 0 -movflags +use_metadata_tags+faststart \
      "$outfile"
  fi

  # Copy file-level metadata (exif/xattr) if exiftool is available
  command -v exiftool >/dev/null && exiftool -overwrite_original -TagsFromFile "$file" -All:All "$outfile" 2>/dev/null || true

  chown st:st "$outfile"
  touch -r "$file" "$outfile"
  rm "$file"
  echo "DONE: $rel"
done

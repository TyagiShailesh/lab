#!/bin/bash
# AV1 delivery encode — Intel (default), AMD, or NVIDIA
# Usage: ffmpeg-av1.sh [amd|nv]
# Creates smaller delivery copies from staging area
# AV1 quantizer scale 0-255 (lower=better), q150 = delivery quality
set -euo pipefail

SRC="/store/media/video/transcode"
DST="$SRC/av1"
CURRENT_OUT=""
trap '[ -n "$CURRENT_OUT" ] && rm -f "$CURRENT_OUT"; exit 1' INT TERM
VID_EXT='mp4|mov|mkv|avi|mts|m4v|mxf|webm|wmv|flv|ts|vob|3gp|ogv|f4v'

# renderD128=AMD, renderD129=NVIDIA, renderD130=Intel
GPU=intel
[[ "${1:-}" =~ ^(amd|radeon)$ ]] && GPU=amd
[[ "${1:-}" =~ ^(nv|nvidia)$ ]] && GPU=nvidia

case "$GPU" in
  nvidia)
    ENC=(-c:v av1_nvenc -preset p7 -tune hq -rc constqp -qp 150
         -profile:v main10 -highbitdepth 1 -bf 4 -rc-lookahead 32 -g 240)
    ;;
  amd)
    ENC=(-c:v av1_vaapi -rc_mode CQP -global_quality 150 -g 240)
    ;;
  intel)
    ENC=(-c:v av1_vaapi -rc_mode CQP -global_quality 150 -g 240)
    ;;
esac

echo "AV1 delivery — $GPU (q150)"

find "$SRC" -path "$DST" -prune -o -type f -regextype posix-extended \
  -iregex ".*\\.($VID_EXT)" -print0 |
while IFS= read -r -d '' f; do
  rel="${f#$SRC/}"
  out="$DST/${rel%.*}.mp4"

  [[ -f "$out" ]] && { echo "SKIP $rel"; continue; }
  mkdir -p "$(dirname "$out")"
  echo "=== $rel ==="
  CURRENT_OUT="$out"

  pix=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$f")

  case "$GPU" in
    nvidia)
      if [[ "$pix" == *422* ]]; then
        echo "  4:2:2 → 4:2:0 (GPU)"
        HW=(-i "$f" -vf 'format=p210le,hwupload_cuda,scale_cuda=format=p010le')
      else
        HW=(-hwaccel cuda -hwaccel_output_format cuda -i "$f")
      fi
      ;;
    amd)
      if [[ "$pix" == *422* ]]; then
        echo "  4:2:2 → 4:2:0 (GPU)"
        HW=(-vaapi_device /dev/dri/renderD128 -i "$f" -vf 'format=nv12,hwupload,scale_vaapi=format=p010')
      else
        HW=(-hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi -i "$f")
      fi
      ;;
    intel)
      if [[ "$pix" == *422* ]]; then
        echo "  4:2:2 → 4:2:0 (GPU)"
        HW=(-vaapi_device /dev/dri/renderD130 -i "$f" -vf 'format=nv12,hwupload,scale_vaapi=format=p010')
      else
        HW=(-hwaccel vaapi -hwaccel_device /dev/dri/renderD130 -hwaccel_output_format vaapi -i "$f")
      fi
      ;;
  esac

  if ! ffmpeg -nostdin "${HW[@]}" "${ENC[@]}" \
    -c:a aac -b:a 192k -map 0:v:0 -map '0:a?' -map_metadata 0 \
    -movflags +faststart "$out" 2>&1; then
    rm -f "$out"
    echo ""
    echo "ERROR: Failed to encode '$rel'"
    echo "  Input:  $f"
    echo "  GPU:    $GPU"
    echo "  Pixel format: $pix"
    exit 1
  fi

  command -v exiftool >/dev/null && exiftool -overwrite_original -TagsFromFile "$f" -All:All "$out" 2>/dev/null || true
  chown st:st "$(dirname "$out")" "$out"
  touch -r "$f" "$out"
  CURRENT_OUT=""
  rm "$f"
  echo "DONE $rel"
done

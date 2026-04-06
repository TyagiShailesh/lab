#!/bin/bash
# AV1 delivery encode — Intel (default), AMD, or NVIDIA
# Usage: ffmpeg-av1.sh [-j JOBS] [amd|nv]
# Creates smaller delivery copies from staging area
# AV1 quantizer scale 0-255 (lower=better), q80 = high quality
set -euo pipefail

SRC="/store/media/video/transcode"
DST="$SRC/av1"
VID_EXT='mp4|mov|mkv|avi|mts|m4v|mxf|webm|wmv|flv|ts|vob|3gp|ogv|f4v'

JOBS=1
while [[ "${1:-}" == -j ]]; do shift; JOBS="${1:?-j requires a number}"; shift; done

# renderD128=AMD, renderD129=Intel
GPU=intel
[[ "${1:-}" =~ ^(amd|radeon)$ ]] && GPU=amd
[[ "${1:-}" =~ ^(nv|nvidia)$ ]] && GPU=nvidia

# Default to 3 parallel jobs for NVIDIA if not specified
[[ "$JOBS" -eq 1 && "$GPU" == nvidia ]] && JOBS=2

encode_one() {
  local f="$1" GPU="$2"
  local rel="${f#$SRC/}"
  local out="$DST/${rel%.*}.mp4"

  [[ -f "$out" ]] && { echo "SKIP $rel"; return 0; }
  mkdir -p "$(dirname "$out")"
  echo "=== $rel ==="

  local pix
  pix=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$f")

  local -a HW ENC
  case "$GPU" in
    nvidia)
      ENC=(-c:v av1_nvenc -preset p4 -tune hq -rc constqp -qp 80
           -profile:v main10 -highbitdepth 1 -bf 4 -rc-lookahead 32 -g 240
           -spatial-aq 1 -temporal-aq 1 -surfaces 64)
      if [[ "$pix" == *422* ]]; then
        echo "  4:2:2 → 4:2:0 (GPU)"
        HW=(-i "$f" -vf 'format=p210le,hwupload_cuda,scale_cuda=format=p010le')
      else
        HW=(-hwaccel cuda -hwaccel_output_format cuda -i "$f")
      fi
      ;;
    amd)
      ENC=(-c:v av1_vaapi -rc_mode CQP -global_quality 80 -g 240)
      if [[ "$pix" == *422* ]]; then
        echo "  4:2:2 → 4:2:0 (GPU)"
        HW=(-vaapi_device /dev/dri/renderD128 -i "$f" -vf 'format=yuv420p10le,hwupload,scale_vaapi=format=p010')
      else
        HW=(-hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi -i "$f")
      fi
      ;;
    intel)
      ENC=(-c:v av1_vaapi -rc_mode ICQ -global_quality 30 -g 240 -async_depth 8)
      if [[ "$pix" == *422* ]]; then
        echo "  4:2:2 → 4:2:0 (GPU)"
        HW=(-vaapi_device /dev/dri/renderD129 -i "$f" -vf 'format=yuv420p10le,hwupload,scale_vaapi=format=p010')
      else
        HW=(-hwaccel vaapi -hwaccel_device /dev/dri/renderD129 -hwaccel_output_format vaapi -i "$f")
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
    return 1
  fi

  command -v exiftool >/dev/null && exiftool -overwrite_original -TagsFromFile "$f" -All:All "$out" 2>/dev/null || true
  chown st:st "$(dirname "$out")" "$out"
  touch -r "$f" "$out"
  echo "DONE $rel"
}

case "$GPU" in
  nvidia) QLabel="qp80" ;; intel) QLabel="icq30" ;; *) QLabel="q80" ;;
esac
echo "AV1 delivery — $GPU ($QLabel, ${JOBS} parallel)"

if [[ "$JOBS" -le 1 ]]; then
  # Sequential mode — simple loop with cleanup trap
  CURRENT_OUT=""
  trap '[ -n "$CURRENT_OUT" ] && rm -f "$CURRENT_OUT"; exit 1' INT TERM
  find "$SRC" -path "$DST" -prune -o -type f -regextype posix-extended \
    -iregex ".*\\.($VID_EXT)" -print0 |
  while IFS= read -r -d '' f; do
    rel="${f#$SRC/}"
    CURRENT_OUT="$DST/${rel%.*}.mp4"
    encode_one "$f" "$GPU"
    CURRENT_OUT=""
  done
else
  # Parallel mode — uses xargs to run JOBS encodes concurrently
  export -f encode_one
  export SRC DST GPU
  trap 'kill 0; wait; echo "Interrupted — partial outputs may need cleanup in $DST"; exit 1' INT TERM
  find "$SRC" -path "$DST" -prune -o -type f -regextype posix-extended \
    -iregex ".*\\.($VID_EXT)" -print0 |
  xargs -0 -P "$JOBS" -I{} bash -c 'encode_one "$@"' _ {} "$GPU"
fi

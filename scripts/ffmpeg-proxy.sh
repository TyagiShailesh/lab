#!/bin/bash
# Proxy media generator — Intel (default), AMD, or NVIDIA
# Usage: ffmpeg-proxy.sh [amd|nv]
# Creates quarter-res H.264 proxies for editing in DaVinci Resolve
# Skips Canon Cinema RAW (.CRM) — ffmpeg has no CRAW decoder
set -euo pipefail

SRC="/store/media/video/roll"
DST="$SRC/proxy"
CURRENT_OUT=""
trap '[ -n "$CURRENT_OUT" ] && rm -f "$CURRENT_OUT"; exit 1' INT TERM
VID_EXT='mp4|mov|mkv|avi|mts|m4v|mxf|webm|wmv|flv|ts|vob|3gp|ogv|f4v|crm'

# renderD128=AMD, renderD129=NVIDIA, renderD130=Intel
GPU=intel
[[ "${1:-}" =~ ^(amd|radeon)$ ]] && GPU=amd
[[ "${1:-}" =~ ^(nv|nvidia)$ ]] && GPU=nvidia

echo "Proxy generation — $GPU"

find "$SRC" -path "$DST" -prune -o -type f -regextype posix-extended \
  -iregex ".*\\.($VID_EXT)" -print0 |
while IFS= read -r -d '' f; do
  rel="${f#$SRC/}"
  out="$DST/${rel%.*}.mp4"

  [[ -f "$out" ]] && { echo "SKIP $rel"; continue; }
  mkdir -p "$(dirname "$out")"

  # detect codec and resolution
  codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$f")
  res=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$f")
  w="${res%,*}"
  h="${res#*,}"
  pw=$(( w / 4 ))
  ph=$(( h / 4 ))
  # ensure even dimensions
  pw=$(( pw + pw % 2 ))
  ph=$(( ph + ph % 2 ))

  # skip formats ffmpeg can't decode
  if [[ "$codec" == "unknown" ]] || [[ "${f,,}" == *.crm ]]; then
    echo "SKIP $rel (Canon Cinema RAW — use Resolve)"
    continue
  fi

  echo "=== $rel ==="
  echo "  ${w}x${h} → ${pw}x${ph}"
  CURRENT_OUT="$out"

  # ProRes RAW has no hardware decoder — CPU decode, GPU encode
  hw_decode=true
  if [[ "$codec" == "prores_raw" ]]; then
    hw_decode=false
    echo "  CPU decode (ProRes RAW)"
  fi

  case "$GPU" in
    nvidia)
      if $hw_decode; then
        HW=(-hwaccel cuda -hwaccel_output_format cuda -i "$f"
            -vf "scale_cuda=${pw}:${ph}")
      else
        # Bayer RAW: CPU debayer + scale, then upload to GPU for encode
        HW=(-i "$f"
            -vf "scale=${pw}:${ph},format=nv12,hwupload_cuda")
      fi
      ENC=(-c:v h264_nvenc -preset p4 -tune hq -rc constqp -qp 22
           -profile:v high -bf 3 -g 240)
      ;;
    amd)
      if $hw_decode; then
        HW=(-hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi -i "$f"
            -vf "scale_vaapi=w=${pw}:h=${ph}")
      else
        HW=(-vaapi_device /dev/dri/renderD128 -i "$f"
            -vf "scale=${pw}:${ph},format=nv12,hwupload")
      fi
      ENC=(-c:v h264_vaapi -rc_mode CQP -global_quality 22 -g 240)
      ;;
    intel)
      if $hw_decode; then
        HW=(-hwaccel vaapi -hwaccel_device /dev/dri/renderD130 -hwaccel_output_format vaapi -i "$f"
            -vf "scale_vaapi=w=${pw}:h=${ph}")
      else
        HW=(-vaapi_device /dev/dri/renderD130 -i "$f"
            -vf "scale=${pw}:${ph},format=nv12,hwupload")
      fi
      ENC=(-c:v h264_vaapi -rc_mode CQP -global_quality 22 -g 240)
      ;;
  esac

  if ! ffmpeg -nostdin "${HW[@]}" "${ENC[@]}" \
    -c:a aac -b:a 128k -map 0:v:0 -map '0:a?' -map_metadata 0 \
    -movflags +faststart "$out" 2>&1; then
    rm -f "$out"
    echo ""
    echo "ERROR: Failed to encode '$rel'"
    echo "  Input:  $f"
    echo "  GPU:    $GPU"
    echo "  Codec:  $codec"
    continue
  fi

  chown st:st "$(dirname "$out")" "$out"
  touch -r "$f" "$out"
  CURRENT_OUT=""
  echo "DONE $rel"
done

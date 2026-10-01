#!/bin/sh
set -eu
# HDR10+ fixtures: 10-bit PQ HEVC with a real ST 2094-40 SEI on every picture,
# in length-prefixed (Matroska) and Annex-B (MPEG-TS) carriage. The encoder
# writes no HDR10+ itself; inject_hdr10plus_sei.py adds the SEI. No B-frames:
# a raw HEVC elementary stream carries no timestamps, and with reordering the
# remux has none to invent, so the muxers refuse it. Verify with:
#   ffprobe -show_frames -read_intervals %+#1 hevc_hdr10plus.mkv | grep 2094-40
# hevc_captioned.mkv is the same picture with A/53 CC1 captions and no HDR10+,
# for the test that the HDR10+ scan does not starve the caption scout.
cd "$(dirname "$0")"
tmp="${TMPDIR:-/tmp}/prismcore-hdr10plus.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT
ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=s=320x180:r=24:d=2" \
  -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast -g 24 \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -x265-params "log-level=error:bframes=0:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" \
  -f hevc -y "$tmp/plain.hevc"
python3 inject_hdr10plus_sei.py "$tmp/plain.hevc" "$tmp/hdr10plus.hevc"
ffmpeg -hide_banner -loglevel error -fflags +genpts -r 24 -f hevc -i "$tmp/hdr10plus.hevc" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" \
  -c:v copy -c:a aac -b:a 64k \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -y hevc_hdr10plus.mkv
ffmpeg -hide_banner -loglevel error -fflags +genpts -r 24 -f hevc -i "$tmp/hdr10plus.hevc" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" \
  -c:v copy -c:a aac -b:a 64k -y hevc_hdr10plus.ts
python3 inject_hdr10plus_sei.py --captions "$tmp/plain.hevc" "$tmp/captioned.hevc"
ffmpeg -hide_banner -loglevel error -fflags +genpts -r 24 -f hevc -i "$tmp/captioned.hevc" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" \
  -c:v copy -c:a aac -b:a 64k \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -y hevc_captioned.mkv

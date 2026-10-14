#!/bin/zsh
# Builds small, unencrypted DVD-Video ISOs used by the DiscCore tests.
# Dev-only: needs Homebrew ffmpeg and dvdauthor (incl. spumux); the UDF image is
# made with the built-in hdiutil.
#
# Tests/Fixtures/basic.iso layout:
#   Title 1 (VTS 1, 16:9 NTSC) 24 s, chapters at 0/8/16 s,
#           audio: AC3 2ch eng (0x80), AC3 2ch fra (0x81), subtitles: eng (0x20)
#   Title 2 (VTS 2, 4:3 NTSC)   6 s, 1 chapter, audio: LPCM 2ch fra (0xA0)
#   Title 3 (VTS 2)            12 s, two cells from separately encoded VOBs, so
#           the MPEG clock restarts at the second cell (an STC discontinuity)
#
# Usage: Scripts/make-fixture.sh [--force]
set -euo pipefail

ROOT="${0:A:h:h}"
OUT="$ROOT/Tests/Fixtures"
ISO="$OUT/basic.iso"

BUNDLE="$OUT/Folder.dvdmedia"

if [[ -f "$ISO" && -d "$BUNDLE" && "${1:-}" != "--force" ]]; then
  echo "basic.iso is up to date (use --force to rebuild)"
  exit 0
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
for tool in ffmpeg spumux dvdauthor; do
  command -v $tool >/dev/null || { echo "error: $tool not found (brew install ffmpeg dvdauthor)"; exit 1; }
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
cd "$WORK"

ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }
NTSC=(-c:v mpeg2video -s 720x480 -r 30000/1001 -b:v 3000k -maxrate 9000k -minrate 0 -bufsize 1835k -g 15 -bf 2 -f dvd -muxrate 10080000 -packetsize 2048)

# Title 1: 16:9, two AC3 tracks.
ff -f lavfi -i "testsrc2=size=720x480:rate=30000/1001:duration=24" \
   -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=24" \
   -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=24" \
   -map 0:v -map 1:a -map 2:a -aspect 16:9 $NTSC \
   -c:a ac3 -b:a 192k -ac 2 -ar 48000 t1-nosub.vob

# One subtitle image (palettized, <= 4 colors as DVD subpictures require).
ff -f lavfi -i "color=c=white:s=240x40" -frames:v 1 -pix_fmt pal8 sub.png
cat > subs.xml <<'EOF'
<subpictures format="NTSC">
  <stream>
    <spu start="00:00:02.00" end="00:00:05.00" image="sub.png" xoffset="240" yoffset="400"/>
    <spu start="00:00:10.00" end="00:00:12.00" image="sub.png" xoffset="240" yoffset="400"/>
  </stream>
</subpictures>
EOF
spumux -s 0 subs.xml < t1-nosub.vob > t1.vob 2>/dev/null

# Title 2: 4:3, a single LPCM track.
ff -f lavfi -i "testsrc=size=720x480:rate=30000/1001:duration=6" \
   -f lavfi -i "sine=frequency=330:sample_rate=48000:duration=6" \
   -map 0:v -map 1:a -aspect 4:3 $NTSC \
   -c:a pcm_dvd -ac 2 -ar 48000 t2.vob

cat > dvd.xml <<'EOF'
<dvdauthor>
  <vmgm/>
  <titleset>
    <titles>
      <video format="ntsc" aspect="16:9" widescreen="nopanscan"/>
      <audio lang="en"/>
      <audio lang="fr"/>
      <subpicture lang="en"/>
      <pgc>
        <vob file="t1.vob" chapters="0,0:08,0:16"/>
      </pgc>
    </titles>
  </titleset>
  <titleset>
    <titles>
      <video format="ntsc" aspect="4:3"/>
      <audio lang="fr"/>
      <pgc>
        <vob file="t2.vob"/>
      </pgc>
      <pgc>
        <vob file="t2.vob"/>
        <vob file="t2.vob"/>
      </pgc>
    </titles>
  </titleset>
</dvdauthor>
EOF
VIDEO_FORMAT=NTSC dvdauthor -o dvd -x dvd.xml >/dev/null 2>&1

# libdvdread locates files through UDF, so the image needs a UDF 1.02 filesystem.
rm -f "$ISO"
hdiutil makehybrid -quiet -udf -udf-version 1.02 -iso -default-volume-name DVDFORGE_FIXTURE -o "$ISO" dvd
# The same disc as a folder copy, the way RipIt-style .dvdmedia bundles store it.
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"
cp -R dvd/VIDEO_TS "$BUNDLE/"

echo "==> Wrote $ISO ($(du -h "$ISO" | cut -f1)) and $BUNDLE"

#!/usr/bin/env bash
# scripts/ci-android-setup.sh
#
# Rebuilds / fetches the binary assets that cannot be pushed through the
# GitHub connector's text-only snapshot push (push_files: UTF-8 only, no
# binaries), so a GitHub Actions Android build can run from the text-only
# source snapshot in this private repo.
#
# What it restores, and why each is missing from the repo:
#   1. android/gradle/wrapper/gradle-wrapper.jar  (binary, gitignored upstream)
#   2. assets/fonts/Outfit-*.ttf                  (binary; pubspec fonts section)
#   3. Launcher icons + banner.png + no_results.png (binary PNGs; aapt needs
#      the mipmap drawables the adaptive icon XML references)
#   4. packages/cs3_engine/m2/                    (CloudStream library AAR/JARs;
#      rebuilt from upstream source at the pinned commit by
#      packages/cs3_engine/tool/build_cloudstream_library.sh)
#   5. packages/flutter_torrent_server/android/repo/.../torrentserver-1.0.aar
#      (built from packages/flutter_torrent_server/go_src/ by build_libs.sh
#      via gomobile; the AAR is what Gradle resolves as com.local:torrentserver)
#
# The generated icons/fonts are placeholders for the CI test build only:
# the real 桃花源 icon and the real Outfit static fonts live in the local
# manual-build workspace and are NOT in this repo. A launch-crash test does
# not depend on them.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== 1. gradle-wrapper.jar ==="
WRAPPER_JAR="android/gradle/wrapper/gradle-wrapper.jar"
if [ ! -s "$WRAPPER_JAR" ]; then
  mkdir -p android/gradle/wrapper
  curl -fsSL -o "$WRAPPER_JAR" \
    "https://github.com/gradle/gradle/raw/v9.3.1/gradle/wrapper/gradle-wrapper.jar"
fi
echo "wrapper jar: $(stat -c%s "$WRAPPER_JAR") bytes"

echo "=== 2. Outfit fonts (variable font copied to the 6 static weight files) ==="
mkdir -p assets/fonts
if [ ! -s assets/fonts/Outfit-Regular.ttf ]; then
  curl -fsSL -o /tmp/Outfit-variable.ttf \
    "https://github.com/google/fonts/raw/main/ofl/outfit/Outfit%5Bwght%5D.ttf"
  for w in Regular Medium SemiBold Bold ExtraBold Black; do
    cp /tmp/Outfit-variable.ttf "assets/fonts/Outfit-$w.ttf"
  done
fi
ls -l assets/fonts/

echo "=== 3. Placeholder launcher icons / banner / no_results ==="
if [ -s android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_foreground.png ]; then
  echo "real launcher icons present, skipping placeholder generation"
else
python3 -m pip install -q pillow || pip install -q pillow
python3 - <<'PY'
from PIL import Image, ImageDraw
import os
# Dark green background (#18251E) with pink blossom dots, matching the 桃花源 theme.
BG = (24, 37, 30, 255)
PINK = (244, 178, 198, 255)
PINK2 = (232, 130, 165, 255)
WHITE = (255, 255, 255, 255)

def petal(d, cx, cy, r):
    for dx, dy in [(0, -r), (r, 0), (0, r), (-r, 0), (int(r*0.7), int(-r*0.7))]:
        d.ellipse([cx+dx-r//2, cy+dy-r//2, cx+dx+r//2, cy+dy+r//2], fill=PINK)
    d.ellipse([cx-r//3, cy-r//3, cx+r//3, cy+r//3], fill=PINK2)

def make_fg(path, size):
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    petal(d, size//2, size//2, size//5)
    petal(d, size//4, size//4, size//8)
    petal(d, 3*size//4, 3*size//4, size//9)
    im.save(path)

def make_bg(path, size):
    Image.new("RGBA", (size, size), BG).save(path)

def make_mono(path, size):
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    petal(d, size//2, size//2, size//5)
    im.save(path)

def make_legacy(path, size):
    im = Image.new("RGBA", (size, size), BG)
    d = ImageDraw.Draw(im)
    petal(d, size//2, size//2, size//5)
    petal(d, size//4, size//4, size//8)
    im.save(path)

for dens, size in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]:
    d = f"android/app/src/main/res/mipmap-{dens}"
    os.makedirs(d, exist_ok=True)
    make_legacy(f"{d}/ic_launcher.png", size)
    make_bg(f"{d}/ic_launcher_background.png", size)
    make_fg(f"{d}/ic_launcher_foreground.png", size * 3 // 2 if dens in ("mdpi",) else { "mdpi": 72, "hdpi": 108, "xhdpi": 162, "xxhdpi": 216, "xxxhdpi": 432 }[dens])
    make_mono(f"{d}/ic_launcher_monochrome.png", size)

# banner (TV leanback, referenced by AndroidManifest) and no_results placeholder
os.makedirs("android/app/src/main/res/drawable-xhdpi", exist_ok=True)
Image.new("RGBA", (320, 180), BG).save("android/app/src/main/res/drawable-xhdpi/banner.png")
os.makedirs("assets/images", exist_ok=True)
im = Image.new("RGBA", (512, 512), BG)
d = ImageDraw.Draw(im)
petal(d, 256, 256, 90)
im.save("assets/images/no_results.png")
# app-internal foreground copy (used by the in-app icon page)
im2 = Image.new("RGBA", (432, 432), (0, 0, 0, 0))
d2 = ImageDraw.Draw(im2)
petal(d2, 216, 216, 86)
im2.save("assets/images/ic_launcher_foreground.png")
print("placeholder icons generated")
PY

fi
echo "=== 4. CloudStream library -> packages/cs3_engine/m2 ==="
if [ ! -f packages/cs3_engine/m2/com/lagradost/api/library-android/1.0.1/library-android-1.0.1.aar ]; then
  # build_cloudstream_library.sh needs JDK 21; runners usually have it as JAVA_HOME_21_X64.
  if [ -n "${JAVA_HOME_21_X64:-}" ]; then
    export JAVA_HOME="$JAVA_HOME_21_X64"
  elif [ -n "${JAVA_HOME_21:-}" ]; then
    export JAVA_HOME="$JAVA_HOME_21"
  fi
  echo "JAVA_HOME for cloudstream build: ${JAVA_HOME:-<unset>}"
  bash packages/cs3_engine/tool/build_cloudstream_library.sh
else
  echo "m2 already present, skipping"
fi

echo "=== 5. TorrServer Android AAR ==="
AAR="packages/flutter_torrent_server/android/repo/com/local/torrentserver/1.0/torrentserver-1.0.aar"
if [ ! -s "$AAR" ]; then
  # build_libs.sh needs Go, gomobile/gobind and the Android NDK.
  export PATH="$PATH:$HOME/go/bin"
  if [ -z "${ANDROID_NDK_HOME:-}" ] && [ -n "${ANDROID_HOME:-}" ]; then
    NDK_DIR="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -n 1 || true)"
    if [ -n "$NDK_DIR" ]; then export ANDROID_NDK_HOME="$NDK_DIR"; fi
  fi
  echo "ANDROID_NDK_HOME: ${ANDROID_NDK_HOME:-<unset>}"
  go version
  go install golang.org/x/mobile/cmd/gomobile@latest
  go install golang.org/x/mobile/cmd/gobind@latest
  bash packages/flutter_torrent_server/build_libs.sh
else
  echo "torrentserver AAR already present, skipping"
fi
ls -l "$AAR"
echo "CI Android setup complete."

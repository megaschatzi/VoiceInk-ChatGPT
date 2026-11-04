#!/bin/bash
# CI helper: use upstream's framework packaging functions, but build only macOS.
set -euo pipefail
WHISPER_REVISION=4da27c41cebadb3cbbcd2563e9c7cbc8d84bdcad
WHISPER_SOURCE="$HOME/VoiceInk-Dependencies/whisper.cpp"
mkdir -p "$(dirname "$WHISPER_SOURCE")"
if [ ! -d "$WHISPER_SOURCE" ]; then
  git init "$WHISPER_SOURCE"
  git -C "$WHISPER_SOURCE" remote add origin https://github.com/ggml-org/whisper.cpp.git
fi
git -C "$WHISPER_SOURCE" fetch --depth 1 origin "$WHISPER_REVISION"
git -C "$WHISPER_SOURCE" checkout --detach "$WHISPER_REVISION"
cd "$WHISPER_SOURCE"
python3 - <<'PY'
from pathlib import Path
source = Path('build-xcframework.sh').read_text()
prefix = source.split('echo "Building for iOS simulator..."', 1)[0]
macos = source.split('echo "Building for macOS..."', 1)[1].split('echo "Building for visionOS..."', 1)[0]
tail = '''
setup_framework_structure "build-macos" ${MACOS_MIN_OS_VERSION} "macos"
combine_static_libraries "build-macos" "Release" "macos" "false"
xcodebuild -create-xcframework \\
  -framework "$(pwd)/build-macos/framework/whisper.framework" \\
  -debug-symbols "$(pwd)/build-macos/dSYMs/whisper.dSYM" \\
  -output "$(pwd)/build-apple/whisper.xcframework"
'''
Path('build-voiceink-macos.sh').write_text(prefix + '\necho "Building for macOS..."\n' + macos + tail)
PY
bash build-voiceink-macos.sh

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Static checks for project configuration. Runs in CI before building.
# Fails with a clear message instead of letting a misconfiguration surface
# later as "music stops when the iPad locks".
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

PLIST=App/WaveLast/Info.plist
plutil -lint "$PLIST" >/dev/null

has_bg_audio() { plutil -extract UIBackgroundModes json -o - "$PLIST" | grep -q '"audio"'; }
check "Info.plist: UIBackgroundModes contains audio" has_bg_audio
check "Info.plist: display name is WaveLast" \
  '[ "$(plutil -extract CFBundleDisplayName raw -o - "$PLIST")" = "WaveLast" ]'
check "Info.plist: multitasking allowed (UIRequiresFullScreen = false)" \
  '[ "$(plutil -extract UIRequiresFullScreen raw -o - "$PLIST")" = "false" ]'
four_orientations() {
  plutil -extract "UISupportedInterfaceOrientations~ipad" json -o - "$PLIST" |
    python3 -I -c 'import json,sys; sys.exit(0 if len(set(json.load(sys.stdin))) == 4 else 1)'
}
check "Info.plist: 4 iPad orientations" four_orientations
check "Info.plist: no blanket NSAllowsArbitraryLoads" \
  '! plutil -extract NSAppTransportSecurity.NSAllowsArbitraryLoads raw -o - "$PLIST" >/dev/null 2>&1'

check "project.yml: bundle id io.github.sabarishpv.wavelast" \
  'grep -q "PRODUCT_BUNDLE_IDENTIFIER: io.github.sabarishpv.wavelast$" project.yml'
check "project.yml: iPad only (TARGETED_DEVICE_FAMILY 2)" 'grep -q "TARGETED_DEVICE_FAMILY: \"2\"" project.yml'
check "project.yml: iOS 17 deployment target" 'grep -q "IPHONEOS_DEPLOYMENT_TARGET: \"17.0\"" project.yml'
check "project.yml: no development team committed" 'grep -q "DEVELOPMENT_TEAM: \"\"" project.yml'

check "LICENSE is GPL-3.0" 'head -3 LICENSE | grep -q "GNU GENERAL PUBLIC LICENSE"'
check "NOTICE credits LastWave-Native" 'grep -q "LastWave-Native" NOTICE.md'

# Every Swift source carries an SPDX header.
missing=$(grep -RL --include='*.swift' "SPDX-License-Identifier: GPL-3.0-only" App Packages/WaveLastKit/Sources Packages/WaveLastKit/Tests || true)
check "all Swift files have SPDX headers" '[ -z "$missing" ]'
[ -n "$missing" ] && echo "$missing"

# Branding: no LastWave name in user-visible identifiers, no reused assets.
check "no LastWave in bundle id / display name" '! grep -iqE "lastwave" "$PLIST" && ! grep -iE "BUNDLE_IDENTIFIER" project.yml | grep -iq lastwave'
check "no files copied from LastWave-Desktop (no .dart / pubspec)" \
  '[ -z "$(find . -path ./.git -prune -o \( -name "*.dart" -o -name pubspec.yaml \) -print)" ]'

# Excluded integrations must not creep in.
check "no Widevine / DRM code" '! grep -RIiqE "widevine|MediaDrm|FairPlayStreaming" App Packages/WaveLastKit/Sources'
check "no YouTube / InnerTube / Tidal / Spotify private endpoints" \
  '! grep -RIiqE "youtubei/v1|music\.youtube\.com|api\.tidal\.com|spclient|sp_dc|amp-api\.music\.apple|apic\.musixmatch" App Packages/WaveLastKit/Sources'

# Secrets: refuse obvious credentials and signing material.
check "no signing material committed" \
  '[ -z "$(git ls-files | grep -iE "\.(p12|mobileprovision|cer|pem|key)$" || true)" ]'
check "no hard-coded 32-hex API keys/secrets in sources" \
  '! grep -RInE "\"[0-9a-f]{32}\"" App Packages/WaveLastKit/Sources'

exit $fail

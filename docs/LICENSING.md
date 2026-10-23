# Licensing obligations

This is an engineering summary, not legal advice.

## Why WaveLast is GPL-3.0

WaveLast adapts logic from LastWave-Native, which is GPL-3.0 (see `NOTICE.md`). An adaptation is a "work based on" the original, so WaveLast must be GPL-3.0 as well. LastWave-Native states version 3 and never says "or any later version". Adapted code therefore can't be offered under later versions, and WaveLast uses **GPL-3.0-only** throughout.

## What we must do

| Obligation | GPL-3.0 section | How WaveLast complies |
|---|---|---|
| Keep the license text | §4, §5 | Full FSF text in `LICENSE`, byte-identical to <https://www.gnu.org/licenses/gpl-3.0.txt> |
| Keep copyright notices and mark changes | §4, §5(a) | Per-file headers name the LastWave-Native source file. `NOTICE.md` lists every adapted file and states that the code was changed (ported to Swift) |
| License the whole work under GPL | §5(c) | `LICENSE`, plus an SPDX header in every Swift file (checked in CI) |
| Show "Appropriate Legal Notices" in an interactive UI | §0, §5(d) | Settings → Licenses & Credits shows the copyright, the GPL notice, "no warranty", and links to the source and the license |
| Provide the corresponding source with every binary given to anyone | §6 | The repository is public. Any distributed IPA must come from a tagged commit, and the release notes must link that commit. Build scripts (`project.yml`, workflow, `scripts/`) are in the repo, so the source is complete |
| No added restrictions | §7, §10 | No extra terms. No DRM or anti-tamper code |

## Practical rules

1. **Don't copy code from LastWave-Desktop.** It has no license, so all rights are reserved. CI fails if Dart or Flutter files appear.
2. **When adapting more Native code,** add a header to the new file and a row to `NOTICE.md` in the same commit.
3. **Don't use the LastWave name, logo or screenshots.** GPL covers code, not trademarks.
4. **Never commit signing material or keys.** CI checks for `.p12`, `.mobileprovision`, `.cer`, `.pem` and `.key` files and for hard-coded 32-hex keys.
5. **Dependencies must be GPL-3.0-compatible** (MIT, BSD, Apache-2.0 or LGPL used dynamically). WaveLast currently uses only Apple system frameworks and has no third-party packages.

## App Store

The App Store's usage rules add restrictions on recipients that conflict with GPL-3.0 §10, and GPL apps have been removed from the App Store for this reason. WaveLast is therefore planned for personal installation, not App Store release. TestFlight has a similar terms question. Using TestFlight only for your own devices is lower risk, but it requires a paid developer membership (see `docs/INSTALL.md`).

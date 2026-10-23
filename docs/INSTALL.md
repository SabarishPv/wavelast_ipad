# Installing WaveLast on an iPad

## What CI produces

| Artifact | What it is | Can it be installed on an iPad? |
|---|---|---|
| `simulator-app` → `WaveLast-iPadSimulator.app.zip` | Build for the **iPad Simulator** (x86_64/arm64 simulator SDK) | **No.** It runs only in the Simulator |
| `unsigned-ipa` → `WaveLast-UNSIGNED.ipa` | Release build for real devices (`iphoneos` SDK), packaged as an IPA, **not signed** | **Not as-is.** iPadOS installs only apps signed with a certificate and a provisioning profile that includes your iPad |
| Signed device IPA | Not produced yet | Requires one of the signing routes below |
| Verified on your iPad | Not yet | Only after you install and test it |

## Why CI can't produce an installable IPA for free

Apple's rules for a **free Apple Account** (a "Personal Team"):

- Provisioning profiles expire **7 days** after they are issued.
- A device can have at most **3** apps installed this way.
- At most **3** devices and **10** App IDs can be registered, and each registration expires after 7 days.
- Certificates, devices and profiles are "managed directly in Xcode". There is no API that CI can call to create them.

(Source: <https://developer.apple.com/support/compare-memberships/>.)

So a free-account IPA has to be signed on your side, either by Xcode or by a sideloading tool that uses your Apple Account. It also has to be re-signed every 7 days. CI can't do this, and it should never hold your Apple Account password.

## Options, cheapest first

### A. Free Apple Account with a sideloading tool (no paid membership)

Tools such as AltStore (with AltServer on a Mac) or SideStore take an unsigned IPA, sign it with your free Apple Account, and install it.

- **Cost:** free.
- **Limits:**
  - Must be refreshed every 7 days.
  - 3 apps per device.
  - The first setup needs a computer (AltServer, or a pairing-file tool for SideStore).
- **What you need to know:**
  - These are third-party tools, not Apple software.
  - They sign in to Apple with your Apple Account. Consider an Apple Account used only for development, and read the tool's documentation and privacy terms before using it.
  - Installing AltServer or a pairing tool is installing software on your Mac. That's your decision; this project doesn't do it for you.
- **Steps:**
  1. Download `unsigned-ipa` from a successful workflow run.
  2. Open `WaveLast-UNSIGNED.ipa` with the tool.
  3. Trust the developer profile in Settings → General → VPN & Device Management.
  4. Turn on Developer Mode if iPadOS asks.

### B. Free Apple Account with Xcode on any Mac

Opening this project in Xcode with your Apple Account signed in (Personal Team) and running it on a connected iPad installs it directly. Xcode generates the project with `xcodegen generate`.

- **Cost:** free.
- **Limits:** the same 7-day limit. You'd have to re-run from Xcode weekly.
- **Note:** this needs Xcode, which you've chosen not to install on your Mac. It could be done on another Mac.

### C. Paid Apple Developer Program (the only route CI can fully automate)

With a paid membership (currently US$99/year; check Apple's current price):

1. Register your iPad's UDID in Certificates, Identifiers & Profiles.
2. Create an **Apple Distribution** certificate and an **Ad Hoc** provisioning profile for `io.github.sabarishpv.wavelast` that includes your iPad.
3. Store these as **encrypted GitHub Actions secrets**, never in the repository: the certificate `.p12` (base64), its password, the profile (base64), and a temporary keychain password.
4. Add a signing step to CI that imports the certificate into a temporary keychain, signs the build, exports an `.ipa` with `xcodebuild -exportArchive` (method `release-testing`, formerly ad hoc), and deletes the keychain.
5. Install the IPA with Apple Configurator, with Finder (drag the IPA onto the iPad), or from a private download link.

Ad hoc profiles last about a year, so there's no 7-day refresh. Internal TestFlight is an alternative; see `docs/LICENSING.md` for the App Store terms question. This step hasn't been added because no paid membership is configured. Tell us if you join and it can be wired up.

## Recommendation

- **To try the app on your iPad soon at no cost:** use **Option A** with the unsigned IPA from CI, and plan for weekly refreshes.
- **To get a signed IPA from CI without weekly refreshes:** use **Option C**. It costs the annual membership fee.

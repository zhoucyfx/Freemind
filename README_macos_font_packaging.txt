FreeMind macOS font rendering and packaging fixes

This document records the macOS-specific fixes added on top of branch 1.1.0
to address Chinese font display problems, blurry Swing text rendering, and
broken bundled-runtime packaging.

Problems solved

1. Chinese and other CJK text could render with missing glyphs or fallback to
   poor fonts on macOS.
2. Swing text looked soft or blurry because text antialiasing and HiDPI-related
   settings were incomplete.
3. Locale parsing in startup logic could select the wrong language variant.
4. The generated macOS app bundle could fail with "Unable to load Java Runtime
   environment" because appbundler 1.0 does not correctly bundle modern JDK
   runtimes by itself.
5. The generated DMG could miss the Applications shortcut, so Finder would not
   show the normal drag-to-Applications install flow.

Root causes

- AWT/Swing antialiasing flags were not consistently enabled in startup and
  packaging paths.
- The default font selection on macOS did not verify that the chosen font could
  display Chinese text.
- The locale parsing logic had a substring bug.
- appbundler 1.0 expects a runtime rooted at Contents/Home and still assumes an
  older JRE-style layout; with JDK 9+ it may only copy a minimal runtime stub.
- JavaAppLauncher bundled by appbundler 1.0 is x86_64-only, so packaging on
  Apple Silicon requires an x86_64 runtime inside the app bundle.
- Fallback DMG creation did not ensure an Applications symlink in the DMG root.

Code changes

- freemind/freemind/main/FreeMindStarter.java
  Adds text rendering configuration early in startup and fixes locale parsing.

- freemind/freemind/controller/Controller.java
  Detects whether the default macOS font can display Chinese text and switches
  to a CJK-capable fallback font if needed.

- freemind/freemind.properties
  Sets antialias = antialias_all by default.

- freemind/freemind.sh
  Adds -Dawt.useSystemAAFontSettings=on and -Dswing.aatext=true.

- freemind/build.xml
  Passes macOS antialiasing options into the app bundle and uses the proper
  macOS runtime directory input for packaging.

- freemind/mac_file_association.xslt
  Ensures NSHighResolutionCapable exists in the generated Info.plist.

- build_macos_dmg_local.sh
  Builds from a local temporary workspace, supports explicit local file
  overlays, resolves an x86_64 macOS runtime, optionally creates a compact
  jlink runtime, hydrates the runtime into FreeMind.app, and guarantees an
  Applications symlink in the final DMG layout.

Build notes

- The repository may live on an external volume that produces intermittent copy
  errors and unreliable executable-bit metadata. The local packaging script
  works around the copy problem by building in /tmp. Git for this working copy
  should use core.filemode=false to avoid false mode-only diffs.

- On Apple Silicon, use a normal JDK for compilation and an x86_64 JDK for the
  bundled app runtime.

Example packaging command

From the repository root:

FREEMIND_LOCAL_OVERRIDE_FILES='freemind/build.xml freemind/freemind/main/FreeMindStarter.java freemind/freemind/controller/Controller.java freemind/freemind.properties freemind/freemind.sh freemind/mac_file_association.xslt build_macos_dmg_local.sh' \
FREEMIND_MAC_RUNTIME_DIR=/tmp/jdk-17.0.2-x64.jdk \
JAVA_HOME=/Volumes/2t/work/code/freemind-code/.toolchain/jdk-17.0.2.jdk/Contents/Home \
PATH=/Volumes/2t/work/code/freemind-code/.toolchain/jdk-17.0.2.jdk/Contents/Home/bin:$PATH \
./build_macos_dmg_local.sh

Expected result

- DMG output path: post/FreeMind_1.1.0_Beta_2.dmg
- App bundle contains a bundled runtime under FreeMind.app/Contents/PlugIns.
- DMG root contains both FreeMind.app and Applications for drag-install.

Result summary

- Chinese text rendering on macOS is readable and uses a CJK-capable font when
  the default system choice is insufficient.
- Swing text rendering is sharper because antialiasing is enabled across
  launcher, app bundle, and runtime startup paths.
- The packaged macOS app starts without the previous Java runtime load failure.
- The compact runtime path keeps the DMG size significantly smaller than a full
  bundled JDK.
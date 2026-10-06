# Installing Dusklight on Apple Vision Pro

This fork of [Dusklight](https://github.com/TwilitRealm/dusklight), the reverse-engineered reimplementation of Twilight Princess, adds a native Apple Vision (visionOS) port. Dusklight is built from the [zeldaret/tp](https://github.com/zeldaret/tp) decompilation and runs on the [Aurora](https://github.com/encounter/aurora) GameCube and Wii runtime. On Apple Vision Pro it renders in a window with a 21:9 presentation. It's verified on the visionOS 26.5 Simulator and on Apple Vision Pro hardware. The full notes are in the [Apple Vision (visionOS) port section of CLAUDE.md](CLAUDE.md#apple-vision-visionos-port).

## What you need

- A Mac with Xcode and the visionOS (xrOS) SDK
- CMake 3.25+ and Python 3, and Ninja, which the CMake presets use
- Rust nightly with the visionOS targets:

  ```sh
  rustup toolchain install nightly
  rustup target add --toolchain nightly aarch64-apple-visionos aarch64-apple-visionos-sim
  ```

- Apple Vision Pro paired with your Mac, with Developer Mode on

- An Apple Development certificate, and a development provisioning profile whose App ID (or wildcard) covers `dev.twilitrealm.dusk` and which includes your Apple Vision Pro
- Your own dump of Twilight Princess for GameCube, USA or EUR release, as ISO (GCM), RVZ, WIA, WBFS, CISO or GCZ

## Your game files

Dusklight does not provide any copyrighted assets. You supply your own copy of the original game.

1. Dump your own disc. The Dolphin wiki's [Ripping Games](https://wiki.dolphin-emu.org/index.php?title=Ripping_Games) article explains how. To save space, you can convert the `.iso` to `.rvz` with [Dolphin](https://dolphin-emu.org/) or [nodtool](https://github.com/encounter/nod/releases). Only the GameCube USA and EUR releases are supported.
2. On the headset, launch Dusklight, press **Select Disc Image** and choose your dump.

You can also copy the dump into the app's `Documents` folder from your Mac, then choose it with **Select Disc Image** (`<device-id>` comes from `xcrun devicectl list devices`):

```sh
xcrun devicectl device copy to --device <device-id> \
  --domain-type appDataContainer \
  --domain-identifier dev.twilitrealm.dusk \
  --source /path/to/game.rvz \
  --destination Documents/game.rvz
```

## Install

There's no prebuilt release for Apple Vision Pro: the visionOS port is built from source.

## Build from source

Start from a checkout of this repository's `main` branch with its submodules (Aurora lives in `extern/aurora`):

```sh
git submodule update --init --recursive
```

1. Configure the device preset. The two flags are needed because Xcode 26.5's clang treats a warning in SDL's UIKit code as an error:

   ```sh
   cmake --preset visionos-default \
     -DCMAKE_OBJC_FLAGS="-Wno-error=return-mismatch" \
     -DCMAKE_OBJCXX_FLAGS="-Wno-error=return-mismatch"
   ```

2. Create the stub header SDL's visionOS layer expects, at `build/visionos-default/_deps/sdl-src/include/SDL3/SDL3-Swift.h`:

   ```objc
   #ifdef SDL_PLATFORM_VISIONOS
   @interface SDL_uikitviewcontroller (SDLVisionOSCurvedUI)
   - (void)initializeVisionOSCurvedUI;   // dynamically dispatched; never sent for this app
   @end
   #endif
   ```

   This SDL fix isn't tracked in the repository, so create the header again after any clean configure.

3. Build:

   ```sh
   cmake --build --preset visionos-default
   ```

   The result is an unsigned `build/visionos-default/Dusklight.app`.

The `visionos-sim-default` preset builds for the visionOS Simulator, with its own copy of the stub header under `build/visionos-sim-default/`; CLAUDE.md covers running it there.

## Install on Apple Vision Pro

The device build is unsigned, so sign it before you install it.

1. Embed your development provisioning profile:

   ```sh
   cp /path/to/profile.mobileprovision build/visionos-default/Dusklight.app/embedded.mobileprovision
   ```

2. Write an entitlements file, `entitlements.plist`, with your 10-character Team ID in place of `TEAMID`:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
     <key>application-identifier</key>
     <string>TEAMID.dev.twilitrealm.dusk</string>
     <key>com.apple.developer.team-identifier</key>
     <string>TEAMID</string>
     <key>get-task-allow</key>
     <true/>
   </dict>
   </plist>
   ```

3. Sign the app and install it on your paired headset:

   ```sh
   codesign --force --generate-entitlement-der \
     --sign "<your Apple Development certificate>" \
     --entitlements entitlements.plist \
     build/visionos-default/Dusklight.app
   xcrun devicectl device install app --device <device-id> build/visionos-default/Dusklight.app
   ```

4. Launch Dusklight from the headset's Home View. Launching it with `devicectl device process launch` stalls on visionOS.

## Notes

- The game plays in a standard window, with the picture held at 21:9 (64:27).
- CLAUDE.md lists a few iOS code paths (the Documents data path, the touch overlay, mobile detection and audio heap sizing) that don't switch on for visionOS yet.

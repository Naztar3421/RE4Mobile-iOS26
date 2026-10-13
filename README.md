# RE4 MCT / Metal Preview

This is an iOS texture-decoder and Metal-display smoke test. It is **not a playable RE4 port** and does not run the original ARMv6 game runtime.

## What the current app does

- Generates a tiny synthetic MCT checkerboard in memory (no copyrighted game assets are bundled).
- Decodes supported MCT layouts into RGBA8: raw RGBA format 2, indexed RGB format 6, indexed RGBA format 7, and the observed sub-block/LZW-compressed format-6 layout.
- Uploads the decoded pixels to an actual `MTLTexture` and displays it through `MTKView` and a native Metal shader.
- Uses the native `UIDocumentPickerViewController` in copy-import mode to open files from the iPhone Files picker, then checks the `.mct` extension before decoding.
- Preserves the original texture aspect ratio during display, composites source alpha over a checkerboard, and provides an optional black-key diagnostic toggle (not claimed as the game's exact transparency rule).
- Shows source dimensions, format/compression flags, RGBA alpha/black pixel counts, byte counts, and SHA-256 hash.
- CI validates four generated asset-free fixtures byte-for-byte: format 2 RGBA, format 6 RGB palette, format 7 RGBA palette, and format 6 sub-block/LZW compression.

The guest-object registry / ARM interpreter and the game's full render-state pipeline are not integrated yet. Passing this stage proves only the MCT → RGBA8 → Metal preview path.

## Build on GitHub Actions

Pushes to `main` run the **Build unsigned iOS preview IPA** workflow. It first compiles and executes the Foundation-only decoder against four generated synthetic MCT fixtures and compares every output byte, then builds an unsigned iOS IPA on a macOS runner and uploads the IPA plus build log as an artifact.

1. Open the repository's **Actions** tab.
2. Open the latest **Build unsigned iOS preview IPA** run.
3. Once successful, download `RE4MCTPreview-unsigned-ipa` from **Artifacts**.
4. The IPA is unsigned: sign it with your own Apple developer identity before installing it on the iPhone.

The repository intentionally excludes the game IPA and extracted game resources. To test an actual texture, transfer an MCT file you are authorized to use into the iPhone's Files app, then choose it from within the preview app. The decoder metadata and displayed output can then be used to check real-device rendering. Do not upload account credentials, certificates, the full IPA, or extracted game resource packs.

## Local build

Install XcodeGen, run `xcodegen generate`, and build the `RE4MCTPreview` scheme in Xcode. The deployment target is iOS 16.0. No JIT or game-engine compatibility is claimed by this project.


## Host-side Upload Bridge smoke test

The app has an optional **上傳路徑：Bridge Smoke Test** switch. It sends the currently imported MCT through RE4GuestTextureUploadBridge and RE4GuestTextureMetalRegistry, asks Metal to create/upload an MTLTexture, verifies lookup by both mock guest-object and mock MCE keys, then verifies that guestObjectDestroyed clears both registry bindings. The renderer retains the returned texture to display it.

This mode deliberately uses synthetic guest address tokens and derives mock width/height/format fields from the MCT header. It validates the Apple-SDK host bridge, registry lookup/lifecycle, and actual Metal texture upload on-device; it does **not** prove that the original ARMv6 guest runtime is connected or that those values came from a live guest MCE table. The ordinary direct-preview route remains available.

The public repository contains only source code and asset-free fixtures; do not commit the original IPA or extracted game assets.


## Captured MVP-18 Load_Obj adapter replay

The optional MVP-18 Load_Obj 回放 mode exercises the guest-memory adapter using the exact captured 2d_fnt_00.mct input (17,450 bytes, SHA-256 4d59a527c44bc8b3a701eeae778564d169cf4e88d7ffa97b0161c8c6c124d00d) and observed guest memory layout:
- guest object: 0x03103100; source MCT input: 0x031095B8
- texture table: 0x03111E70, count at +0x28, array pointer at +0x2C
- texture array: 0x03111EA0; first MCE texture: 0x0310DA00
- MCE width/height at +44/+46, pixel format at +0x30

The app reconstructs only these captured fields in sparse test memory, calls the same post-return adapter contract expected from a future live interpreter, checks metadata against the decoded MCT, uploads a real MTLTexture, verifies registry lookups, and checks cleanup. No original MCT or IPA is bundled. This is captured-memory replay, not a live ARMv6 interpreter on iOS; a future runtime should call the adapter after Load_Obj returns at 0x1C318 and preserve arguments captured at 0x1C314.


## ARMv6 core port — first incremental milestone

RE4GuestARMv6Runtime.swift adds a bounds-checked 32-bit guest address space and an interpreter for the targeted ARM instruction subset observed in the MVP-14/15/18 harness: ARM condition flags, data-processing, basic load/store, block transfer, branch/BX/BLX, halfword/signed loads and the exact legacy VFP operations used by the Load_Obj path. Platform calls are left to an explicit host instruction hook. This is not a complete ARMv6 emulator yet.

The app's ARMv6 核心指令自測 runs a generated, asset-free instruction sequence checking arithmetic/flags, a taken branch, LDR/STR and BX LR. Passing validates only this CPU subset. Next steps are Mach-O/IPA loading, the imported-symbol/HLE map, the ACV/H2Z resource boundary, and then the real Load_Obj entry/return callback.

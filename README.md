# RE4 MCT / Metal Preview

This is an iOS texture-decoder and Metal-display smoke test. It is **not a playable RE4 port** and does not run the original ARMv6 game runtime.

## What the current app does

- Generates a tiny synthetic MCT checkerboard in memory (no copyrighted game assets are bundled).
- Decodes supported MCT layouts into RGBA8: raw RGBA format 2, indexed RGB format 6, indexed RGBA format 7, and the observed sub-block/LZW-compressed format-6 layout.
- Uploads the decoded pixels to an actual `MTLTexture` and displays it through `MTKView` and a native Metal shader.
- Uses the native `UIDocumentPickerViewController` in copy-import mode to open files from the iPhone Files picker, then checks the `.mct` extension before decoding.
- Shows the source dimensions, format/compression flags, byte counts, and SHA-256 hash to help compare decoder results.

The guest-object registry / ARM interpreter and the game's full render-state pipeline are not integrated yet. Passing this stage proves only the MCT → RGBA8 → Metal preview path.

## Build on GitHub Actions

Pushes to `main` run the **Build unsigned iOS preview IPA** workflow. It first compiles and executes the Foundation-only decoder against a generated synthetic MCT fixture, then builds an unsigned iOS IPA on a macOS runner and uploads the IPA plus build log as an artifact.

1. Open the repository's **Actions** tab.
2. Open the latest **Build unsigned iOS preview IPA** run.
3. Once successful, download `RE4MCTPreview-unsigned-ipa` from **Artifacts**.
4. The IPA is unsigned: sign it with your own Apple developer identity before installing it on the iPhone.

The repository intentionally excludes the game IPA and extracted game resources. To test an actual texture, transfer an MCT file you are authorized to use into the iPhone's Files app, then choose it from within the preview app. The decoder metadata and displayed output can then be used to check real-device rendering. Do not upload account credentials, certificates, the full IPA, or extracted game resource packs.

## Local build

Install XcodeGen, run `xcodegen generate`, and build the `RE4MCTPreview` scheme in Xcode. The deployment target is iOS 16.0. No JIT or game-engine compatibility is claimed by this project.

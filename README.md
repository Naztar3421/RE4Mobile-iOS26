# RE4 MCT / Metal Preview

This repository currently contains a minimal iOS Metal rendering smoke-test app. It draws a generated shader pattern and is intended to verify the native Metal view/pipeline path.

**Current limitation:** the MCT decoder and game runtime have not yet been integrated into this repository. This is not a playable RE4 app. The repository intentionally excludes the game IPA and extracted game assets.

## Cloud build

GitHub Actions uses a macOS runner and Xcode to build an unsigned IPA. See Actions → Build unsigned iOS preview IPA. The IPA must be signed with your own Apple developer identity before installation; an unsigned IPA cannot be installed directly.

## Build locally

Install XcodeGen, then run `xcodegen generate` and build the `RE4MCTPreview` scheme in Xcode. The GitHub Actions workflow performs the unsigned device build and packages the app as an IPA.

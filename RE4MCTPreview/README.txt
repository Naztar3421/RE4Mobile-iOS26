RE4 MCT / Metal Preview

This is a minimal iOS Metal rendering smoke-test app.
It currently draws a generated checkerboard-like triangle using a Metal shader.
It does NOT yet include the MCT decoder and does NOT run the Resident Evil 4 game engine.
The repository intentionally excludes the game IPA and extracted game assets.

Build:
GitHub Actions runs on pushes to main and via workflow_dispatch.
The artifact is an unsigned IPA; it must be signed with your own Apple developer identity before installation.

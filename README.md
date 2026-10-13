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


## Mach-O 32-bit ARM inspection milestone

RE4MachO32Parser.swift parses thin and universal FAT 32-bit ARM Mach-O headers, LC_SEGMENT/sections, LC_UNIXTHREAD ARM PC, LC_MAIN entry offsets, dylib dependencies, nlist undefined symbols, indirect symbol pointer/stub imports, section relocations, and classic dyld bind/weak/lazy bind streams. It creates a bounds/overlap-checked guest-memory load plan but does not apply relocations/binds or execute the file.

The on-device **Mach-O 32-bit ARM 解析器自測** uses a generated fixture (thin ARMv6 and universal FAT wrapper) containing synthetic segments, a dylib, an undefined _malloc symbol, an indirect pointer, an external relocation and a dyld bind stream. **檢查 Mach-O 執行檔** accepts a raw executable copied from an extracted `.app`; the IPA ZIP itself is not a Mach-O image. No original game binary or asset is committed.


## Mach-O segment mapper — incremental milestone

`RE4MachO32Loader.swift` maps validated segments at their declared guest virtual addresses, excludes `__PAGEZERO`, clears each full VM range, copies the file-backed prefix, and reports zero-fill bytes. It checks that the entry PC is within a mapped executable segment and refuses invalid memory/file ranges. Segment protections are reported, not enforced.

The on-device **Mach-O Segment Mapper 自測** uses a generated asset-free ARMv6 Mach-O fixture to verify `__TEXT`, `__DATA`, `__LINKEDIT` mapping, entry opcodes, zero-fill clearing, file offsets, and rejection when guest memory is too small. **載入 Mach-O 至 Guest Memory** accepts a raw main executable extracted from the app bundle, selects its 32-bit ARM slice and maps it into the 80 MiB guest address space, retaining image and memory for follow-on work. This step does not apply relocations/binds, resolve imports/HLE, run initializers, or execute guest code.


## Legacy Mach-O import binding plan

RE4MachO32ImportBindingPlan.swift expands the older LC_DYSYMTAB indirect-symbol table into per-site records, distinguishing non-lazy pointer (section type 6), lazy pointer (type 7), and symbol-stub (type 8) sites. It groups sites by unique imported symbol, classifies names into preliminary families (C runtime, Objective-C runtime, C++ ABI, Apple frameworks, game/engine, or review required), and checks whether each site falls inside a declared guest segment.

Family labels are an inventory aid only; they do not mean the underlying API has been implemented. The on-device '產生 Res4 的 HLE 匯入計畫' reports the actual imported-symbol plan for the already mapped executable. 'HLE 匯入繫結計畫自測' uses a generated asset-free _malloc lazy-pointer fixture. This milestone does not allocate thunks, patch pointers, load dylibs, or execute imports.


## Explicit HLE trap binding — first callable subset

RE4MachO32HLEBinder.swift assigns deterministic trap addresses to a deliberately small libc-style subset: malloc/calloc/realloc/free, memcpy/memmove/memset/memcmp/memchr, strlen/strnlen/strcmp/strncmp/strcpy/strncpy/strchr. It patches only pointer-table entries for those symbols. Symbol-stub code remains unchanged and reaches the HLE trap through its pointer indirection. Unsupported imports remain unresolved.

RE4GuestARMv6HLEDispatcher is connected to the ARM core pre-fetch instruction hook. It emulates this subset using bounds-checked guest-memory copies and returns to the guest LR. The allocator is conservative: free does not recycle memory, and realloc allocates/copies instead of resizing in place. This is not a full POSIX/libSystem implementation.

The synthetic HLE test maps a generated Mach-O, patches the _malloc lazy pointer, dispatches the trap through the ARM core, verifies return through LR, and then exercises _memset and _memcpy traps. The on-device button “套用已支援的 HLE 匯入繫結” patches only the already mapped in-memory Res4 image; it does not run its entry point or initializers.


## ARMv6 entry-point static preflight

`RE4ARMv6EntryPreflight.swift` inspects up to 64 ARM instruction words from a loaded executable entry point without executing them. It labels common branch, block-transfer, single-transfer, extra-transfer and data-processing encodings; records branch targets; and explicitly flags SVC/coprocessor or unclassified encodings as requiring review. A handler-class label is not a proof of full instruction semantics.

The on-device “檢查 Entry PC 指令（不執行）” reads from the already mapped guest memory. The synthetic fixture entry stream is generated MOV r0,#1 / ADD r0,r0,#2 / BX lr, which is decoded by the self-test but never executed by this preflight. This step must pass before designing a bounded real-entry trace; it does not start the original game's entry point or run Objective-C initializers.


## ARMv6 entry control-flow / literal-pool static analysis

The on-device entry inspection button now decodes a restricted sequential path through common ARM data-processing and LDR/STR instructions, tracks only statically knowable register values, resolves PC-relative LDR literal references and statically inferable BLX/BX targets, then stops at an unconditional BX without following it. Referenced literal words are labelled as data, not instructions. The report explicitly states that guest execution and HLE dispatch did not occur and that Mach-O fixups remain unapplied; inferred targets are not proof of runnable code.

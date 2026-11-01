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

`RE4MachO32Loader.swift` maps validated segments at their declared guest virtual addresses, excludes `__PAGEZERO`, clears each full VM range, copies the file-backed prefix, and reports zero-fill bytes. It checks that the entry PC is within a mapped executable segment and refuses invalid memory/file ranges. Initial per-segment R/W/X protections are enforced after segment bytes and zero-fill are installed.

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


## Read-only pointer/fixup audit

The parser now reports the external/local relocation tables declared by `LC_DYSYMTAB` (`extreloff/nextrel` and `locreloff/nlocrel`) separately from section relocation records and dyld bind streams. These tables are decoded and reported, not applied.

The on-device “檢查 Entry 間接指標／Fixup（唯讀）” audits the two pointer slots inferred from the current Res4 ARMv6 entry-path report (`0x001C13DC` and `0x001C13E0`). It shows the containing segment/section, backing file offset and raw word, current mapped word, classic indirect-symbol entry, section/dynamic relocation matches, and dyld bind records. These preset addresses apply to the tested Res4 build only.

A zero pointer is not assumed to be null or to require relocation. The audit only reports whether the parser found a matching import/fixup-related record for that exact slot. No pointer is modified and no guest code executes.


## Classic non-lazy import slot and guest _exit

The Res4 pointer audit identifies `0x001C13E0` as a `__DATA,__nl_symbol_ptr` slot whose classic indirect symbol is the undefined external `_exit`. The zero in the on-disk slot is treated as unresolved import state, not as a resolved function pointer. Since this old-style image has no dyld bind stream, the indirect-symbol table plus symbol table is the relevant import inventory for a legacy binder; the presence/absence of a relocation record at the exact slot alone is not decisive.

The HLE subset now includes `_exit`, but it never invokes host process termination. It requests a guest-runtime halt and returns a result with `halted=true`, `returned=false`, and the guest exit code. The synthetic test checks that this call stops only the emulator loop and does not return through LR or terminate the iOS app. This does not enable or initiate execution of Res4's real entry point.


## First indirect entry target audit

The UI has a read-only audit preset for address `0x00011FC0`, the address statically inferred from the entry path's first `BLX r12`. It reports exact defined symbol-table matches, nearby symbol labels (explicitly not function boundaries), and a bounded static instruction path starting at that address. It never calls the target, invokes HLE, changes pointer slots, or executes guest instructions. The address preset is tied to the tested Res4 ARMv6 slice.


## PIC-style PC-indexed LDR analysis

The ARMv6 static entry analyzer now resolves a known register-offset `LDR` whose base is `PC`, using the ARM architectural PC value (instruction address + 8), U bit, and shifted-register offset. It records the effective address, loaded word, and containing segment/section when known. It also annotates exact defined-symbol labels for direct branch/call targets and drops caller-saved register assumptions after an unconditional `BL`, so stale pre-call values are not silently propagated. Unknown/overflowing load addresses clear the destination register from the static state.

A synthetic self-test writes generated ARM instructions and a marker word into zero-filled guest memory, then verifies that `LDR r1,[pc,r0]` reads the expected address/value. It performs static reading only: no synthetic instruction is executed. This is particularly relevant to the Res4 `_main` path, which uses `LDR [PC, Rm]` after loading offset values from its literal pool.


The static disassembler also recognizes ARM block-transfer instructions such as the _main prologue `0xE92D40F0`, reporting `STMDB sp!, {r4, r5, r6, r7, lr}` instead of an opaque `.word`. A synthetic assertion covers this encoding.


## Static call-path boundary and direct _main call targets

The sequential ARMv6 inspection stops when an `LDM*` instruction loads `PC` from its register list, e.g. `LDMIA sp!, {r4, r5, r6, r7, pc}`. The stack and restored return address are not modeled, so bytes after that return sequence (which may be a literal pool) are not reported as reachable sequential instructions. A synthetic test verifies that a marker word immediately after the LDM return is not scanned.

The UI also has a static audit preset for the two direct call targets seen in the inspected `_main` path: `0x001A0558` and `0x0019FC70`. Each report includes symbols near the target and a bounded instruction scan. Neither call target is invoked and no guest instructions execute.


## Imported-pointer stub control flow

Both observed direct-call targets (`0x001A0558` and `0x0019FC70`) begin with the pattern `LDR r12, [pc]` followed by `LDR pc, [r12]`; their literal words point to pointer slots `0x001C19F4` and `0x001C16FC`, which the read-only report showed currently dereference to `0x00008DD0`. The static analyzer now stops at an unconditional word `LDR` that loads `PC`, reports the resolved indirect destination when known, and does not decode the following literal-pool word as reachable code. A synthetic test checks this boundary.

Two additional read-only controls are available:
- inspect the shared destination `0x00008DD0` without calling it;
- audit the two pointer slots against raw file words, mapped words, section/indirect-symbol metadata, relocation tables and dyld binds.

No code, pointer slot, or HLE binding is changed by these diagnostics.


## Classic dyld lazy-binding audit (read-only)

The “檢查舊式 dyld lazy binding／__dyld 區段（唯讀）” report dumps the parsed `__DATA,__dyld` section as raw-file and guest-mapped words, inventories classic `__la_symbol_ptr` entries from the indirect-symbol table, cross-references per-slot dyld bind records, and counts pointers that still target the in-image `dyld_stub_binding_helper`. It also reports when a non-zero value falls outside the executable's mapped VM segments.

This audit is diagnostic only: it neither invokes the dyld helper nor patches or resolves imports. The observed `0x2FE01000` value is classified by address range only; its exact owning system mapping is not inferred from the executable alone.


## Classic dyld format triage (read-only)

The lazy-binding report now reads `LC_SYMTAB`, `LC_DYSYMTAB`, and `LC_DYLD_INFO`/`LC_DYLD_INFO_ONLY` fields directly from the selected Mach-O slice. It reports file-bound checks for the symbol/string, indirect-symbol, external-relocation and local-relocation tables, along with opcode-stream offsets/sizes. It also summarizes `LC_DYSYMTAB` external relocation types/symbols and indirect-import section kinds.

When bind/weak/lazy opcode sizes are zero while the indirect-symbol and external-relocation tables are populated, the report labels that as **consistent with** the classic symbol/relocation metadata path. It does not assume zero bind records means zero imports, nor does it apply relocations or execute the helper. The `__DATA,__dyld` words remain raw data and are not interpreted as function pointers absent stronger format evidence.


## Classic external-relocation audit (read-only)

The current Res4 ARMv6 slice has no `LC_DYLD_INFO`/`LC_DYLD_INFO_ONLY` command, but declares 1,943 `LC_DYSYMTAB` external relocation records. A separate in-app audit now inventories each target address, containing segment/section, source file offset and raw word, mapped word, symbol index/name, and the symbol's `n_desc` library ordinal mapped to the ordered dependent dylibs. It summarizes relocation signatures, target sections, raw values, dependent dylibs and frequent symbols.

This remains a metadata report only: it does not infer an addend formula, resolve a symbol to a host address, patch pointers, register Objective-C/C++ metadata, or execute code. Its purpose is to establish the exact legacy relocation requirements before any resolver is implemented.


The relocation audit now emits the full sorted record list after its summaries and representative rows. Each row contains the VM target address, segment/section, file offset, ARM relocation type and width, external/PC-relative/scattered flags, symbol table index/name, decoded `n_desc` library ordinal and dependency path, and raw versus mapped word. The synthetic fixture's external relocation address is an absolute VM address within its `__DATA` section, matching the loaded-image format being audited.


## One-tap full relocation report export

The relocation audit UI retains its on-screen summary and 25-record pages, and adds a one-tap export action. It regenerates the same read-only audit report and writes one UTF-8 `.txt` file containing export metadata, the entire audit summary, representative records, and the complete sorted relocation inventory. The native iOS share sheet is then presented so the user can save the single file to Files or share it. Export does not apply relocations, alter guest memory, or execute guest code. The report can be regenerated from a freshly loaded Mach-O to establish a clean analysis baseline.


## Sparse Guest Memory and pinned iOS 4.2.1 shared cache

The runtime memory model now keeps the original low Guest VA byte array (default 80 MiB) for Res4, heap, stack, return sentinel and existing HLE, and adds independently mounted sparse regions above that range. Sparse regions carry a Guest VA base, length, shared file backing, backing offset, maximum protection and initial protection.

- Multiple regions can reference the same immutable `RE4GuestMemoryBacking`. Writes to writable regions are stored in 4 KiB shadow pages, so the source shared-cache Data is not modified and the DATA mapping does not require copying the entire cache into a second mutable buffer.
- Data reads/writes and ARM instruction fetches are checked separately. Sparse R-X, R-W and R-only mappings enforce their permissions; writable+executable mappings, overlaps, unmapped gaps and cross-region accesses are rejected.
- The Mach-O segment mapper applies each main-image segment's initial protection only after its file-backed bytes and zero-fill bytes have been installed. The legacy low memory outside protected Mach-O ranges remains permissive for the existing heap/HLE harness.
- The pinned iOS 4.2.1 / Build 8C148 / ARMv6 shared-cache mapper validates the exact 166,722,970-byte file SHA-256, cache magic, three mapping-table records, slide metadata and code-signature tail before atomically mounting four sparse ranges: TEXT R-X, DATA R-W, LINKEDIT R-only and code-signature tail R-only.
- The app exposes **Sparse Guest Memory／R-W-X 權限自測** and **掛載 iOS 4.2.1 ARMv6 shared cache（slide=0）**. Select the extracted `dyld_shared_cache_armv6` file from Files. The importer retains the security-scoped URL while the memory backing is in use.

This milestone is deliberately pinned to **slide=0**. Non-zero slides are rejected until cache slide/fixup processing is implemented. Mounting the shared cache does not itself resolve the 357 indirect-import-only symbols, apply the 1,943 Res4 external relocations, run dyld initializers, register Objective-C/C++ runtime state, or execute guest code. It only makes the verified cache bytes addressable through the sparse Guest Memory API. The 21 dylib providers share one cache backing; the cache is not extracted into 21 duplicated images.

## Stage G — isolated Res4 external-relocation staging

The Stage G control accepts the pinned 31,088-byte Stage D overlay file `RE4_StageD_Relocation_Overlay_Records_LE.bin`. It verifies the overlay SHA-256, the selected Res4 ARMv6 thin-slice SHA-256, the iOS 4.2.1 / 8C148 shared-cache SHA-256, the exact Res4 segment layout, and every relocation's target/file-offset/addend/candidate address against the currently loaded Guest Memory.

Only after all 1,943 live target words match their original on-disk values does it create a new minimal Guest Memory, remap Res4 and the immutable shared-cache backing, apply the relocation words there, and read all 1,943 values back. The final image and unchanged original image are checked against the pinned Stage D baseline and relocated SHA-256 values. The original loaded Guest Memory is never written by this procedure.

To run it on-device:
1. Mount the verified iOS 4.2.1 Build 8C148 ARMv6 shared cache.
2. Load the matching Res4 executable into Guest Memory.
3. Transfer the supplied Stage D overlay `.bin` file into Files and use **Stage G：預檢並隔離套用 1,943 筆 external relocation**.
4. Select the overlay. On success, the report will show `Stage G isolated external relocation apply PASS`; the detailed 1,943-row read-back CSV can be exported from the app.

This stage does not install the separate 357 indirect-import-only symbols, lazy binds, HLE, dyld initializers, Objective-C/C++ constructors, or execute guest instructions. The relocated image is retained separately as staging memory for the next validation step.

## Stage H — isolated native indirect-import staging (42 non-lazy pointers)

RE4IOS421ImportBindingStager.swift consumes the pinned 672-row Stage H import-site crosswalk CSV. The importer validates the file SHA-256 and 23-column schema, then cross-checks all 672 rows against the parsed Res4 LC_DYSYMTAB indirect-symbol table, nlist symbol indexes, indirect-table indexes, dylib ordinals/dependency paths, section/file offsets, provider cache mappings, cache permissions, and ARM Thumb-state bits. Stub/lazy-pointer pairs are checked by symbol index and embedded literal address.

To run this step on-device:
1. Complete Stage G successfully, retaining the isolated relocated image.
2. Select the Stage H import-applier control in the app.
3. Choose RE4_StageH_Import_Binding_DryRun_672.csv from the Stage H verification package.
4. On success, export the 42-row non-lazy pointer readback CSV from the app.

Stage H creates a second, fresh Guest Memory and remaps Res4 plus the pinned immutable shared-cache backing. It copies only Stage G's relocated __DATA segment into the new image, verifies the Stage G image hash, and writes exactly 42 candidate pointers into __DATA,__nl_symbol_ptr. The 315 lazy pointers remain 0x00008DD0; all 315 symbol stubs remain byte-for-byte unchanged. It reads back all 42 writes, verifies no byte changed outside those pointer slots, checks the expected final image hash, and rehashes the Stage G input to prove it remained unchanged.

This is isolated native-pointer staging only. It does not modify the original loaded Guest Memory or Stage G memory, does not run the lazy-binding helper, does not execute guest instructions, does not invoke HLE, and does not run initializers or constructors. The staged image is not yet permission to start the game's entry point.


## Stage J — isolated ARM/Thumb state model and read-only initializer audit

The standalone `RE4ARMv6InstructionSetState.swift` tests the architectural target-state decision for `BX` and `BLX register`: bit 0 selects Thumb versus ARM, with halfword versus word address alignment. It is a pure address/state model only. It does **not** mutate the interpreter's CPSR, implement a Thumb decoder, or make the guest runtime executable. Synthetic vectors include the Stage I-D Thumb provider pointer and the ARM `_main` address.

`RE4MachO32InitializerAudit.swift` reads the ordered `S_MOD_INIT_FUNC_POINTERS` array from a staged Guest Memory image, checks pointer preservation against the original thin Mach-O bytes, labels ARM/Thumb targets, validates `__TEXT` RX containment, and performs a bounded read-only scan of ARM control-flow evidence. It follows unconditional in-image `B` edges (including common initializer veneers), records direct ARM `BL` targets, maps exact symbol-stub addresses back to imported symbol names, and recursively inspects bounded local callees. The CSV records import call-site counts and unresolved transfers for each initializer. Conditional branch alternatives are recorded but not traversed; indirect calls, exact function extents, inline-data boundaries, Thumb bodies and provider implementations remain explicit unknowns. A bounded linear scan is evidence, not a complete control-flow graph. No guest instruction, initializer, constructor, dyld helper, or HLE trap is invoked.

The on-device Stage J control is enabled only after Stage I-D succeeds in the same app session. It exports a per-initializer CSV and a text report. Host CI uses generated synthetic Mach-O fixtures to validate the state-transition model, ordered initializer parsing, direct local-call evidence, and read-only memory invariant; this does not constitute real-device runtime execution.


## Stage J.1 — conditional control-flow worklist and SJLJ/LSDA crosswalk

`RE4MachO32InitializerControlFlowAudit.swift` extends Stage J without changing Stage I-D memory. It reads instructions, symbols, initializer slots and `__gcc_except_tab` only through the read-only Guest Memory interface.

- A bounded worklist follows both successors of direct conditional ARM `B` instructions: the taken target and the fallthrough address. Direct `BL` imports and local callees are recorded as graph edges. Register-derived transfers and other unresolved exits are reported rather than guessed.
- Function regions are bounded using the nearest defined `N_FUN` / `N_SECT` symbol in `__TEXT,__text`. This is an analysis boundary, not proof of compiler function extents or a complete ARM disassembler.
- For SJLJ functions, the audit statically resolves the PC-relative LSDA pointer from the function's literal load / PC-add sequence, parses the `__gcc_except_tab` call-site table as ULEB128 `(cs_lp, action)` pairs (with landing-pad dispatch index `cs_lp + 1`), and recovers local stored `call_site` selectors where supported. The selector is compared with the one-based LSDA table-row ordinal.
- It correlates recovered stored `call_site` selectors with one-based LSDA table-row ordinals (the landing-pad dispatch index is `cs_lp + 1`), and recognizes the shared cleanup block by the bounded branch-over-cleanup / `__Unwind_SjLj_Resume` pattern. Cleanup imports are listed separately from normal and conditional-path imports.
- It exports three files: per-initializer dependency summary CSV (22-column header), control-flow edge CSV, and SJLJ/LSDA crosswalk CSV, plus the full text report. The dependency summary distinguishes positive SJLJ selector/store-to-direct-BL correlations from distinct LSDA rows matched, and the text report de-duplicates static imported call sites across path labels.
- The control-flow edge CSV also includes supplementary `exception_cleanup` rows for recognized direct ARM `B/BL` instructions inside the bounded branch-over-cleanup region. The report counts cleanup words inspected and cleanup edges emitted separately. This is not a reconstruction of the incoming landing-pad dispatch edge: indirect or stack-derived transfers and runtime exception selection remain unresolved.

The original `ExtraProductList` initializer provides a useful static cross-check: its function body at `0x5188` registers SJLJ state at `0x51D4`, the LSDA pointer resolves to `0x001C0996`, and the parsed call-site table contains 20 rows. The current host-side original-binary harness records 20 store-to-direct-BL call-site records against 20 LSDA rows, but the crosswalk is not one-to-one: 19 distinct table rows have at least one code-site match, table row 1 remains unmatched, and table row 2 is referenced by two static call instructions at `0x555C` and `0x5588`. A further instruction-level check found `0xFFFF0000` stored to the SJLJ `call_site` field at `0x51FC` before the `ios_base::Init` call at `0x5204`, and `0xFFFFFFFF` stored at `0x560C` before `__Unwind_SjLj_Resume` at `0x5610`. Both signed-negative values are consistent with the no-action handling in the Apple LLVM-GCC 4.2 SJLJ implementation; the exact iOS 4.2.1 provider runtime was not dynamically tested. Row 1 therefore has no observed positive selector in this initializer; row 2 is selected by both calls at `0x555C` and `0x5588`. This is consistent with shared table selection, not proof of runtime exception success or failure. The shared cleanup block `[0x55A8, 0x5614)` contains one static wide-string destructor call site at `0x55FC` and `__Unwind_SjLj_Resume` at `0x5610`. The destructor is in a loop and may execute more than once at runtime; the CSV count is a static call-site count, not a dynamic invocation count. The device readback also showed that the same `__Unwind_SjLj_Unregister` instruction at `0x5618` is reachable under both normal and conditional path labels; this is one static call site, not two. The sum of path-labelled entries may therefore exceed the de-duplicated static import-site total.

Stage J.1 remains static analysis only. It does not call the personality routine, unwinder, landing pad, initializer, constructor, dyld helper, HLE trap, or guest entry point; it performs no Guest Memory writes. Conditional worklist reachability and SJLJ table matches are code/metadata evidence, not proof that runtime exception dispatch succeeds. Indirect calls, data-dependent control flow, Thumb bodies, full ARM semantics, and providers' runtime readiness remain outside scope. Host synthetic tests and host-side analysis of the original binary do not constitute a real-device Stage J.1 readback or a playable runtime.

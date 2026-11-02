# Stage J.6 — SJLJ / `___gxx_personality_sj0` Regression Scope

Target: iOS 4.2.1 / build 8C148 / ARMv6. This stage is a host-only contract model for the cleanup-only LSDA associated with Res4 ExtraProductList initializer #101.

## CI

Run `bash tools/validate-stage-j6.sh`. This is an independent GitHub Actions step; it compiles only the J.6 model, J.6 tests, and a tiny CLI entry point. It does not rely on or replace the J.4 provider regression runner.

## Pinned profile

- Personality: `___gxx_personality_sj0` in `libstdc++.6.dylib`, VA `0x374EF9F8`.
- LSDA: VA `0x001C0996`, function VA `0x00005188`.
- Header: `FF FF 03`; ULEB128 call-site table length `0x28`.
- Twenty indexed pairs: selector/index 0 through 19, action offset 0.
- J.1 crosswalk: 19 distinct rows matched, 20 static correlations; row 1 has no static callsite match, row 2 has two static callsites.

## Model scope

The tests cover the bounded LSDA parser, the #101-only personality outcomes, synthetic per-thread SJLJ frame chains, phase 1, normal phase 2, forced phase 2, and Resume private-word routing. Out-of-profile selector values are deliberately unresolved.

## Safety and limits

No shared-cache function, personality, unwinder, landing pad, ARM/Thumb instruction, Guest Memory region, or raw callback pointer is executed or dereferenced. `INSTALL_CONTEXT` is a metadata plan only. The model does not reconstruct actual landing-pad PCs, install registers, transfer control, implement typed catches, or claim general DWARF/GCC exception compatibility. A passing CI step proves only that the host model and its pinned synthetic fixtures compile and pass.

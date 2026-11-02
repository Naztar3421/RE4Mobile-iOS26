# Stage J.6 — SJLJ / ___gxx_personality_sj0 Regression Scope

Target: iOS 4.2.1 / build 8C148 / ARMv6. This stage is a host-only contract model for the cleanup-only LSDA associated with Res4 ExtraProductList initializer #101.

## CI

Run \`bash tools/validate-stage-j6.sh\`. This is an independent GitHub Actions step. It does not rely on or replace the J.4 provider regression runner.

## Pinned profile

- Personality: ___gxx_personality_sj0 in libstdc++.6.dylib, VA 0x374EF9F8.
- LSDA: VA 0x001C0996, function VA 0x00005188.
- Header: FF FF 03; ULEB128 call-site table length 0x28.
- Twenty indexed pairs: selector/index 0 through 19, action offset 0.
- J.1 crosswalk: 19 distinct rows matched, 20 static correlations; row 1 has no static callsite match, row 2 has two static callsites.

## J.7 correction: INSTALL_CONTEXT retains current frame

The initial J.6 interpretation that INSTALL_CONTEXT unlinked the selected SJLJ frame was incorrect. The pinned 8C148 _unwind_phase2 path passes the current frame pointer (r4) to _pthread_setspecific before restoring R7, SP, and PC. The current frame therefore remains the thread-specific top while the cleanup continuation runs. Res4's cleanup trampoline writes 0xFFFFFFFF to frame+4 and calls __Unwind_SjLj_Resume; the 32-bit GetIP helper wraps this sentinel to zero, allowing the resumed phase-2 walk to continue past the cleaned frame. The current J.6 model and tests include this correction, and J.7 separately verifies the static frame/context mapping.

## Safety and limits

No shared-cache function, personality, unwinder, landing pad, ARM/Thumb instruction, Guest Memory region, or raw callback pointer is executed or dereferenced. INSTALL_CONTEXT and the J.7 context plan are metadata only. The J.7 bounded #101 static analysis reconstructs cleanup continuation 0x55A8, but does not install CPU registers, perform BX, implement typed catches, or claim general DWARF/GCC exception compatibility.

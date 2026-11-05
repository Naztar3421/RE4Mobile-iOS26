# RE4 Stage J.7 — Res4 #101 Landing-Pad / SJLJ Context Reconstruction

Target: Res4 ARMv6 slice and iOS 4.2.1 / 8C148 shared cache. Scope is read-only static reconstruction plus host-only metadata tests.

## Result

The cleanup continuation for ExtraProductList initializer #101 is 0x000055A8. This is recovered from the SJLJ frame's saved continuation word at frame+0x24, not by treating an LSDA selector as an address.

At 0x5198, the function first reserves 0x60 bytes from SP. At 0x51A4 it forms the SJLJ frame base as post-prologue SP+0x18. At 0x51C4 it loads literal 0x3D4 from 0x5638; 0x51CC uses architectural PC 0x51D4, so 0x51D4+0x3D4=0x55A8. At 0x51D0 this is stored at SP+0x3C, i.e. frame+0x24.

The personality is ___gxx_personality_sj0 at 0x374EF9F8 in libstdc++.6.dylib. In the #101 zero-action path, BGE at 0x374EFDF0 skips the block that would write context+0x24. It then calls __Unwind_SetGR(context,0,exception), __Unwind_SetGR(context,1,0), __Unwind_SetIP(context,dispatchIndex), and returns 7 (INSTALL_CONTEXT). SetGR writes frame+8+4*register; SetIP stores dispatchIndex-1 at frame+4 and does not modify frame+0x24.

The actual 8C148 _unwind_phase2 INSTALL_CONTEXT branch passes current frame r4 to _pthread_setspecific, then restores R7 from frame+0x20, SP from frame+0x28, PC from frame+0x24, and BXes that PC. This retains the current frame at TSD top. It does not unregister the frame before entering cleanup.

At cleanup continuation 0x55A8, Res4 reads [SP+0x20], which is frame+8 (GR0), saves the exception pointer at [SP+0x10], then cleans the initialized wide-string prefix in reverse. It writes 0xFFFFFFFF to frame+4 and calls __Unwind_SjLj_Resume. The 32-bit GetIP helper calculates frame+4 plus one, so the sentinel wraps to zero and Resume continues past the already-cleaned frame.

The normal completion branch at 0x55A4 skips the cleanup trampoline and reaches __Unwind_SjLj_Unregister at 0x5618. The exceptional cleanup path uses Resume instead.

## LSDA mapping

The LSDA header is FF FF 03, call-site table length 0x28, with 20 entries for selectors 0..19 and action offsets 0. J.1 has 19 distinct matched rows and 20 static callsite correlations. Row 1 is unmatched; row 2 maps both 0x555C and 0x5588. These are static correlations only. Selector 0 means no completed strings require cleanup; selectors 1..19 request the same cleanup continuation with that many completed objects.

## Validation

Corrected J.6 host-only SJLJ/personality regression: 20/20 PASS. J.7 frame/context static evidence regression: 26/26 PASS. CI runs J.6 and J.7 as separate workflow steps.

No target function, personality, unwinder, pthread TSD, landing pad, ARM/Thumb instruction, Guest Memory, register file, or control transfer is executed or modified. 0x55A8 is the bounded #101 cleanup continuation; this does not establish a generic LSDA landing-pad address. Typed catch support, arbitrary LSDA profiles and full Guest Runtime readiness remain unsupported.

# iSH+ ARM-to-ARM translator ("ishjit") — plan

Goal: run the guest's AArch64 code close to native speed on the iPad (A13) and
Mac, inside the existing QEMU system emulator, keeping full-system Linux
(4 KB pages, so FEX keeps working) and every device, the GIC, timers, GPU,
snapshots and the iOS JIT setup as they are.

## Why a new translator

QEMU's TCG decodes each guest instruction into generic ops and generates host
code from them. Same-ISA guests pay the full price of that path. Measured on
the benchmark loops (see docs in the QEMU perf notes), executed host code is:

| | share |
|---|---|
| real work | 28% |
| TLB checks (8-9 insns per load/store) | 28% |
| guest registers loaded/stored to memory | 28% |
| NZCV flags computed in software | 6% |
| per-block bookkeeping | 6% |
| helper calls (TBL, widening ops...) | 3% + helper time |

Guest and host are both AArch64. Most instructions can run as they are, with
only their register numbers changed; flags live in the host's real NZCV; FP
and SIMD run on the host's own units with the guest's FPCR. What can't run as
is: memory accesses (guest virtual addresses, translated through the guest's
page tables), PC-relative instructions, branches, and system instructions.

## Design

### Where it plugs in

`tb_gen_code()` (accel/tcg/translate-all.c) calls `setjmp_gen_code()` to fill
the code buffer, the per-instruction unwind data (`gen_insn_end_off`,
`gen_insn_data`: guest PC + 2 ARM words per instruction) and the two
`goto_tb` patch offsets. ishjit produces the same things for a block, or
declines and TCG translates it. So:

- Everything else in QEMU stays: TB lookup, jump cache, chaining, cpu_exec,
  interrupts, exceptions, cpu_restore_state, self-modifying-code tracking,
  TB invalidation, the code buffer (split W^X on iOS), the TLB and its fill.
- Coverage can grow one instruction class at a time; anything not handled
  falls back to TCG per block. There is never a "doesn't boot until done"
  phase.
- A switch (`-accel tcg,ishjit=on|off`) and a per-block fallback reason
  counter.

### Registers

Host x18 is reserved by Apple (zeroed on context switches) and host SP must
stay a valid host stack (signals). Available: x0-x17, x19-x30 = 30 registers.

- x19 = env (QEMU's convention, so TCG blocks and ishjit blocks chain).
- 2 host scratch registers for address computation and the TLB check
  (x16, x17, the TCG backend's own temporaries).
- 27 guest registers (26 GPRs and SP) live permanently in host registers.
  The 5 least used live in env and are loaded into a scratch when used.
  Measured (2026-11-13, register accesses of all executed instructions over
  the Ubuntu workload incl. the kernel, a13=on): x18 0.09%, x13 0.17%,
  x15 0.17%, x14 0.29%, x28 0.32% — together 1.0% of accesses, so these
  five go to memory. Most used: x0 16%, x1 11.4%, x2 7.9%, x4 6.5%,
  XZR 6.2%, SP 6.1%, x19 5%, x3 4.9%.
- Register numbers in each copied instruction are rewritten through a
  guest→host map (5-bit fields; the map is fixed so the rewrite is a table
  lookup).
- v0-v31 map 1:1 to host v0-v31. The prologue additionally saves d8-d15
  (callee-saved, TCG's prologue doesn't).
- Guest NZCV lives in host NZCV. Inserted code (TLB checks, branches) uses
  only flag-free instructions (cbz/cbnz/tbz, eor, add), so flags survive.
- Guest FPCR is installed in host FPCR on entry and restored on exit to C
  code; FPSR accumulates natively and is merged back.

### Entering and leaving blocks

Each ishjit block has two entry points:
- slow entry: loads the guest registers, NZCV and FPCR from env (used when
  coming from the cpu_exec loop or a TCG block);
- fast entry: registers already live (used when chained from another ishjit
  block).

Exits to the cpu_exec loop, to TCG blocks and into helpers that may read env
or longjmp store the live registers back ("sync"). Chained ishjit→ishjit
jumps (goto_tb patching, the same mechanism TCG uses) go to the fast entry, so
hot code runs entirely in host registers across blocks.

### Memory accesses

Each guest load/store becomes:
1. the effective address computed into a scratch (all addressing modes,
   pre/post-index writeback applied separately);
2. an inline lookup in QEMU's existing softmmu TLB (same CPUTLBEntry format,
   same mmu_idx rules, so fills, flushes, ASID stashes, dirty tracking,
   watchpoints and MMIO all keep working): ~5-6 flag-free host instructions;
3. the original instruction, rewritten to use the host address.

The slow path (TLB miss, MMIO, code page written) syncs registers and calls
QEMU's existing load/store helpers; faults are precise because the unwind
data maps the host return address back to the guest instruction.

Special cases: LDP/STP and multi-register SIMD loads get one check for the
whole access when it can't cross a page; exclusives (LDXR/STXR) follow
QEMU's cmpxchg-based model at first; LSE atomics run natively on the host
address; DC ZVA, prefetches and cache maintenance go to helpers or are
dropped (prefetch).

### Everything else

- Direct branches: goto_tb chaining (within a page) or the inline jump-cache
  lookup (across pages); conditional branches keep using host NZCV.
- BL/ADR/ADRP/literal loads: computed from the block's guest PC (blocks are
  PC-relative like TCG's CF_PCREL ones, so shared libraries are translated
  once for all processes).
- MRS/MSR, SVC/HVC/BRK, ERET, WFI, cache maintenance, TLBI, ISB/DSB: sync and
  call the existing TCG helpers, ending the block where TCG does.
- Single-step, watchpoints, icount, record/replay, AArch32: TCG.

### Guest CPU model

Copied instructions must exist on the host, and iSH+ is public: it runs on
the A13 and on every later Apple chip (A14-A19, M1-M5...). So the guest gets
the instruction features of the host it runs on, read at startup (sysctl
hw.optional.arm.FEAT_*), intersected with what ishjit handles:

- The A13 (ARMv8.4: LSE, LSE2, RDM, CRC32, AES/SHA1/SHA2/SHA3/SHA512, FP16,
  FHM, DotProd, JSCVT, FCMA, LRCPC/2, FlagM, DIT, DPB) is the minimum; the
  `a13=on` CPU option (done, Phase 0) caps `-cpu max` to it.
- Later chips add features (M1/A14: FlagM2, FRINTTS, SB, SSBS, DPB2; newer
  ones BF16, I8MM, and on recent chips possibly more); each one is offered to
  the guest only when the host has it and ishjit either copies it or leaves
  it to TCG. The option becomes `host-features=on`, with `a13=on` kept for
  testing the minimum on any machine.
- The feature set is part of the saved VM state: instant resume on a host
  with fewer features (an iCloud restore to an older device) boots fresh
  instead of resuming into instructions the CPU lacks.
- Features with global effects stay off regardless (SVE/SME, MTE, BTI,
  PAuth, FEAT_AFP) unless ishjit grows support for them.

Software built for plain ARMv8 is unaffected; glibc picks its routines at run
time (on an A13 it stops using MOPS).

## Expected speed (vs native, from the generated-code analysis)

| workload | QEMU 1.0.4 | ishjit target |
|---|---|---|
| integer/branchy loops | 2-7x | 1.2-1.6x |
| FP / SIMD loops | 5-8x | 1.2-2x |
| memory-heavy loops | 2-18x | 2-4x (TLB check per access) |
| translation of cold code (gcc, Firefox start) | slow | several times faster to translate |
| kernel-heavy (syscalls, fork) | 5-14x | better, still limited by exception emulation |

Memory-heavy code is the limit: without the host MMU translating guest
addresses (impossible with 4 KB guest pages on 16 KB iOS pages, see the
failed hybrid window), each access keeps a short software TLB check.

Why the guest keeps 4 KB pages: FEX hard-codes a 4 KB page size
(`FEX_PAGE_SIZE = 4096`, FEXCore/Utils/TypeDefines.h), so FEX's Linux mode
needs a 4 KB-page kernel. Madeira (willfaust/Madeira) runs FEX on iOS's 16 KB
pages only because it uses FEX's Windows mode under Wine (ARM64EC/WOW64),
where Wine itself emulates Windows' 4 KB page protections on 16 KB host pages
and FEX's self-modifying-code detection works per 16 KB page ("hot SMC
pages" for data sharing a page with code). Its FEX fork (willfaust/FEX,
branch ios-port-2607) changes the allocator, JIT memory and SMC handling, not
FEX's Linux page-size assumption. A 16 KB guest kernel would therefore break
x86 Linux programs under FEX (Windows games through Wine could still work, as
in Madeira).

## Phases

0. **Groundwork**: A13 guest CPU model (measure TCG with it); instruction
   frequency profile of the Ubuntu workload to choose the in-memory guest
   registers; a randomized instruction test generator that runs the same
   programs natively (OrbStack) and in the VM and compares results; switch
   and fallback statistics.
1. **Integer ALU + branches**: decoder for the data-processing classes,
   register rewriting, host NZCV, block end at branches with TCG-compatible
   exits; slow entry/exit only. TCG still handles any block with memory
   accesses. First speed check on the ALU benchmarks.
2. **Loads and stores**: inline TLB lookup, slow-path helpers, unwind data,
   all addressing modes, LDP/STP, SIMD loads/stores, atomics, exclusives.
   Linux boots with most kernel and user code in ishjit.
3. **FP and SIMD**: identity-mapped vector registers, FPCR/FPSR handling,
   all FP/AdvSIMD data-processing instructions copied.
4. **Registers across blocks**: fast entry, chaining between ishjit blocks,
   sync only on real exits.
5. **System instructions and exceptions**: everything still falling back
   that matters in the kernel (MRS/MSR, ERET, SVC, TLBI...), so whole kernel
   paths stay in ishjit.
6. **Speed work**: TLB check tuning, call/return prediction for indirect
   branches, block layout.
7. **iOS**: split W^X code buffer, icache, the iPad's feature check; FEX and
   desktop tests; release behind a setting first, then default.

Each phase ends with the full test set (boot, Ubuntu workload, stress test,
randomized instruction tests, CPU benchmark) and an A/B timing against the
previous phase. Commits go to deps/qemu `ishplus`, new code in
`accel/tcg/ishjit/`.

## Correctness

- Fallback by default: any instruction the decoder doesn't fully know →
  TCG for that block.
- Randomized instruction tests compared with native execution.
- A check mode that runs each ishjit block, then re-runs it under TCG from
  the same saved state on a copy of the touched memory, and compares
  registers and memory (development only).
- The existing workload, stress test (COW, gcc correctness) and boot tests.

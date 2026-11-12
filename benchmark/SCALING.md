# Downscaled decoding

The decoder can reconstruct ProRes at **1/2, 1/4, or 1/8 resolution** (`scale: 2 | 4 | 8`) for fast preview and
scrubbing — no post-decode pixel scaling. Each 8×8 block keeps only its top-left **K×K** low-frequency DCT
coefficients (K = 8/scale → 4, 2, 1) and is reconstructed with a reduced **K-point inverse DCT**; the AC entropy
decode stops as soon as the remaining coefficients fall outside that band.

Downscaled decoding is gated entirely behind `scale > 1`. The full-resolution path is untouched (see *Why 1× is
unchanged* below).

## Speedup vs full-resolution decode

Node.js v26, Apple M5 Max (18 cores), best of 5 iterations, median of 3 runs (each iteration aggregates ~400 ms of
work). MT = multi-threaded (shared memory).

| content | 1/2 | 1/4 | 1/8 | MT 1/2 | MT 1/4 | MT 1/8 |
|---|--:|--:|--:|--:|--:|--:|
| 1080p 422 Proxy | 1.67× | 2.70× | 6.89× | 1.52× | 1.62× | 2.30× |
| 1080p 422 Standard | 1.70× | 4.03× | 13.03× | 1.31× | 1.62× | 3.26× |
| 8K 4444 | 2.07× | 5.20× | 18.70× | 1.77× | 3.47× | 6.43× |
| buck-bunny (422 HQ) | 1.97× | 5.07× | 13.19× | 1.40× | 1.83× | 3.16× |
| buck-bunny-444 (444 HQ) | 2.05× | 5.91× | 17.89× | 1.69× | 2.62× | 3.92× |
| transparent (4444 alpha) | 1.57× | 2.38× | 2.88× | 1.43× | 1.89× | 2.14× |
| 4444 12-bit | 2.54× | 4.70× | 7.73× | 1.31× | 1.67× | 1.97× |

1/4 and 1/8 are large, universal wins, and **1/2 is 1.5–2.5× single-threaded across every content type** (figures vary
somewhat with machine load). Multi-threaded speedups are necessarily smaller — a 1080p frame's *entire* decode is
already ~0.4 ms once split across 18 cores, so there is little absolute time left to remove — but the work-aware
scheduling described below keeps MT 1/2 at 1.3–1.8× and MT 1/8 at 2–6.4×. Alpha content (transparent) gains less
because the alpha plane is run-length coded and parsed in full at every scale. Interlaced content is
full-resolution only.

## Techniques, most to least important

Reaching these numbers was *not* about a faster transform — the reduced path is bound by the entropy parse and by
the per-output-pixel write/convert work, not by IDCT multiplies. Each technique below was validated by leave-one-out
(toggled off and re-benchmarked).

1. **Truncate, don't round, in the f32→integer convert.** This was the single dominant fix. The reduced kernel
   originally did `@round` (WASM `f32x4.nearest`) on every output sample before narrowing — and that rounding, not
   the transform, was the bottleneck. The full-resolution `idct_8x8` already truncates via a saturating `f32→u32`
   (the dc-offset carries the level shift), so matching it is both faster and more consistent. **Removing the round
   took 1080p Proxy 1/2 from 0.72× to 1.67×** and lifted every content type past 1×.

2. **Transform a whole macroblock together, store last.** All of a macroblock's blocks are loaded and transformed
   into f32 output rows before *any* store to the frame buffer. Keeping every load ahead of every store removes a
   false store→load aliasing hazard (the compiler otherwise serializes the blocks, fearing the frame writes alias the
   coefficient reads), so the independent block transforms pipeline. **Proxy 1/2 0.56× → 0.79×.**

3. **AC entropy-decode cutoff.** The AC stream is scan-order-major, so once the scan index passes the last position
   inside the kept K×K band, every remaining coefficient is high-frequency and is skipped. This is the main lever for
   high-AC content: at 1/2 it lifts 8K 1.50× → 2.07×, 422 HQ 1.26× → 1.97×, and 4:4:4 HQ 1.18× → 2.07×, and it is what
   lets the deeper scales stretch — without it, 1/8 stalls near 1.3–1.7× instead of reaching 13–18×. (Low-AC content
   like Proxy exhausts its coefficients before the cutoff, so it benefits little — 1.57× → 1.67× — and relies on #1/#2
   instead.)

4. **Coalesced wide stores + wide convert.** For the 2×2 (luma / 4:4:4) macroblock layout, the two
   horizontally-adjacent blocks' output rows are joined into one 2K-wide vector, then clamped, narrowed, and stored in
   a single wide write — instead of four narrow K-wide writes per row. This runs the `u32→u8/u16` narrow at full SIMD
   width and halves the store count. Helps the store-heavy cases most (8K 1/2 1.55× → 1.74×).

5. **Skip the coefficient zero-fill at 1/8.** At 1/8 the reduced IDCT reads only each block's DC coefficient, which
   the DC pass always writes, so the (otherwise required) zeroing of the sparse AC scratch is unnecessary. **~1.3× at
   1/8** (1080p 422: 0.47 → 0.36 ms), free at other scales.

6. **Skip off-grid alpha samples when downscaling.** The alpha plane is run-length coded (not DCT), so it must be
   parsed in full at every scale to stay in sync with the stream — but at scale>1 only one sample per scale×scale
   block is kept. The run loop now skips off-grid rows wholesale and steps by the scale factor within on-grid rows,
   instead of grid-testing every sample. Bit-identical output; and because alpha is parsed at *both* scales, trimming
   it raises the 1/2 ratio (a cost shared by numerator and denominator). This is what takes the alpha-bearing formats
   over 1.5×: transparent 1/2 1.47× → 1.57×, and it lifts 8K/12-bit 4444 too.

## Tried and removed (didn't earn their complexity)

- **4-point even/odd butterfly** for the K=4 transform (5 multiplies/transform vs 16 for the direct cosine matmul):
  bit-equivalent up to float reassociation, but **no measurable speedup** — the reduced IDCT is not multiply-bound.
  Removed in favor of the simpler direct matmul.
- **Compact / contiguous coefficient buffer:** the strided top-left-corner loads were not the bottleneck, and the
  associated memset shrink (below) is small.
- **Memset shrink at 1/2 and 1/4:** measurable but tiny (~0.05× on Proxy), not worth the bookkeeping.

## Multithreading: sizing the workers to the work

The shared-memory decoder splits a frame's slices across workers that pull from a shared atomic counter. A downscaled
frame does far less work per slice, so waking all ~18 workers on a small one loses more to dispatch and counter
contention than it gains — 1080p 1/2 peaks around half the workers and gets *slower* beyond that, which is why the
naive MT 1/2 speedups sat near 1.0×. Two adjustments fix this (single-threaded and full-resolution decoding are
untouched, and the output stays byte-identical):

- **Work-aware worker cap.** For a chroma-only downscale, the worker count is capped by the frame's total work
  (parsed bytes + bytes written), so a 1080p downscale uses about half its workers while an 8K frame still uses all of
  them. Alpha-bearing frames are exempt — the run-length alpha plane is decoded in full at every scale, so it keeps
  enough work to feed every worker (this is what regressed when the cap was tried on output size alone).
- **Main-thread participation.** When the cap leaves a core spare, the main thread — which would otherwise just idle
  on the completion wait — joins in and decodes slices from the same counter, for concurrency+1 effective decoders. It
  does so only when no other packet is queued, so it never steals the main thread from a decode pipeline, and only
  when a core is actually free, so it never over-subscribes the CPU.

Together these lift MT 1/2 on chroma-only content from ~1.0–1.3× to ~1.3–1.5× and cut 1/8 latency substantially
(e.g. 1080p Standard MT 1/8 2.4× → 3.3×, 4:4:4 HQ MT 1/8 3.1× → 3.9×).

## Why 1× (full-resolution) decoding is unchanged

Everything above is gated behind `scale > 1`. Crucially, the full-resolution path *already* uses the same core
techniques — it truncates (no round), converts at full SIMD width, and computes all four macroblock blocks before
storing — which is exactly why it was several× more efficient per output pixel than the first naive reduced kernel.
Bringing the reduced path up to that same standard is what these changes do; they add only a never-taken,
`@branchHint(.unlikely)` cutoff guard to the shared AC-decode loop (~0.002% of an 8K decode), so 1× decode speed is
unchanged. The multithreading adjustments above are likewise gated to `scale > 1`: the worker cap never fires at full
resolution, and the main thread only joins in when the cap has freed a core, which never happens for a 1× decode.

# Duplicate Model Reassessment Research Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for scoped diagnostic probes; keep product implementation paused. The user has authorized investigation and model comparisons in the current thread.

**Goal:** Explain the real same-frame false negatives and determine whether acquisition, conversion, or model selection needs reconsideration.

**Architecture:** Keep the frozen product and QA evidence unchanged. First replay the exact captured MB-043 tensors with the official SSCD weights, then isolate PhotoKit acquisition with bounded reads of the same original asset. Compare suitable licensed models on frozen labels, with input provenance and negatives included.

**Tech Stack:** Swift / public PhotoKit / existing PhotoSyncCore, official TorchScript and locally available PyTorch models, Apple Vision, Python analysis.

**Spec:** `docs/superpowers/specs/2026-09-28-photosync-0.2.0-advanced-dedup-design.md`; user instruction on 2026-10-11 authorizing further cause investigation and reassessment using the 19 real pairs plus original fixtures.

## Global Constraints

- No product model, threshold (`0.98`), source, production database, or Photos mutation. Beta, canary, merge and packaging remain on hold during this research.
- Private media, metadata and tensors stay in ignored `work/`; never upload or include them in tracked research summaries.
- Preserve the original 50 labels: 19 same-frame pairs and 31 distinct pairs. Use the active 33-case fixture suite; do not restore the 11 excluded information-panel cases or removed rotation cases.
- Keep image inspection with blinded subagents. Preserve stamps, asset revisions, model hashes, input hashes, run failures and actual process exit evidence.
- Model-specific distances are not interchangeable with SSCD cosine `0.98`. Observed separability is diagnostic, not a new independent calibration or a production false-skip guarantee.
- Original-resource access is restricted to the already authorized diagnostic asset, streamed with a cap and cleanup/drain evidence. Never download the whole iCloud library for this experiment.

## Review Focus

- Conversion and inference backend must be tested on identical Float32 input bytes, without another image resize.
- A PhotoKit rendered original is not assumed to be the original encoded resource; compare bytes and common decoding when available.
- Low-resolution proxies and native original inputs must have separate provenance and conclusions.
- Hard negatives involving depth blur, tonal edits and framing must remain in comparisons even when positives improve.
- Failed reads, model loads and incomplete cases remain explicit missing results, never negative predictions.

---

### Task 1: Exact official-weight replay

**Files:** Private probes and results in `work/real-photos-icloud/20261010-bounded-mobilebackup/analysis/model-reassessment/official-replay/`.

- [x] Pin the official Large TorchScript SHA `16a196359f91e5fc4e774d5679244c8a661c182309ad4ede0c7e83f6a9861fa0` and the three MB-043 captured tensors.
- [x] Infer on exactly `1x3x320x320` Float32 values; report output shape, normalization, pair cosines and correspondence with saved CoreML vectors. No Source or Photos reads.
- [x] Verify hashes and independent cosine recomputation; report whether conversion/backend differences can account for the observed `0.914595`.

### Task 2: Acquisition controls for MB-043

**Files:** Private Swift probe and results in `analysis/model-reassessment/acquisition/`, reusing the unchanged frozen Core.

- [x] Prepare a read-only probe for the same asset original: `PHAssetResourceManager.requestData`, with a 64 MiB streamed cap, expected asset revision, source stamp, request timeout/cancel/drain and no Photos write API.
- [x] Obtain original encoded bytes if available, compare SHA with the Source file, and decode both through the same current ImageIO/preprocessor path. A failed read remains unresolved evidence.
- [x] Separately request original PhotoKit rasters at target sides 320, 640, 1600 and 4096, sequentially with current 512 MiB budget and 30-second image deadline. Record actual dimensions and score the captured tensors with unchanged SSCD.
- [x] Independently check the probe before live reads, then verify completed outputs and physical drain. Attribute any improvement only to the controlled input change.

### Task 3: Frozen-cohort model comparison

**Files:** Private benchmark manifest, scripts and results in `analysis/model-reassessment/comparison/`.

- [x] Reuse licensed cached weights first: SSCD Large, SSCD ResNet50 mixup, standard DINOv2, SigLIP-family models and Apple Vision where available. Verify each exact model and license; no gated or noncommercial weights for a shipping recommendation.
- [x] Pin the 50 real-pair labels and active 33 fixture cases. Use the existing proxy images for a screening matrix and explicitly retain that input limitation; use actual captured tensors only for compatible SSCD replay.
- [x] Apply each official native preprocessing recipe and record embedding size/distance definition. Compute all pair results, distributions and overlap; do not reuse SSCD's threshold for unrelated models.
- [x] Measure local warm inference and peak process memory with model loads separated, one model process at a time. State CPU/MPS/Vision/CoreML backend and avoid claiming ANE performance from PyTorch.
- [x] Check label/image custody and recompute metrics independently. If proxy quality limits a conclusion, report the exact follow-up rather than silently changing labels or taking a new production decision.

### Task 4: Research conclusion

**Files:** Public aggregate report in `docs/research/advanced-dedup/2026-10-11-model-reassessment.md`; detailed private tables/HTML in the research directory.

- [x] Cite the official SSCD preprocessing, published score interpretation, complete issue-history search and candidate license sources.
- [x] Separate demonstrated causes, rejected explanations and remaining uncertainty; include recall and hard-negative tradeoffs.
- [x] Recommend the next product direction with concrete evidence. Any model/acquisition/product change needs a subsequent approved design and implementation scope; this research does not itself alter shipping behavior.

## Self-review

The requested investigation and potential model reconsideration are covered by Tasks 1–4. Privacy, bounded live reads, negative controls, input custody and model-specific score interpretation each have an explicit verification step. This plan introduces private probes only; it does not revise the approved product architecture or revive canceled population calibration.

## Execution result (2026-10-11)

Tasks 1–4 completed. The one-asset source/original byte and common-decoder control is identical; PhotoKit target 320 / 640 / 1600 / 4096 scores are 0.914457 / 0.982387 / 0.996123 / 0.997965. Seven PyTorch matrices plus Vision, each 83 cases, are complete. All model CPU/MPS controls and saved score/custody recomputation passed; the first SigLIP class-load failure is preserved. The follow-up 19-pair high-quality acquisition experiment is a recommendation, not an executed product change.

Report: `docs/research/advanced-dedup/2026-10-11-model-reassessment.md`. Private interactive report: `work/real-photos-icloud/20261010-bounded-mobilebackup/analysis/model-reassessment/review.html`. Independent result check: `analysis/model-reassessment/independent-results-check.md` (SHA256 `88996d756110ee1aae99e905db67c1d89c309e0e4dca1f7ac5cf913a0b4d3a98`). All live probes exited; no canary, product migration or release was run.

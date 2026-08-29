# Ollama Model Catalog — Unverified Assumptions

**Status:** the catalog ships as guidance, not as measurement. Every row in
`environments/ollama/models.tsv` is assembled from Ollama's published model
pages and upstream release notes; none of the 32GB-tier entries has been pulled
and run on a host this repo manages. The README states the caveat where it
applies; this file tracks what would retire it.

## 1. The 32GB tier's whole premise is an upstream claim

`mac32` exists because Ollama 0.19 moved Apple Silicon inference to MLX and
reported roughly double the decode rate, with a hard 32GB unified-memory floor
for the new backend. Not confirmed locally:

- That the MLX backend actually engages on the operator's 32GB Mac, and on
  which of the catalog's models — it shipped as a preview covering a limited
  set of architectures (Qwen first), so `devstral:24b` and `gpt-oss:20b` may
  still be running through the older path on the same machine.
- Whether `ollama ps` or any other command reports which backend served a
  request. If it does, `manage-models.sh --resources` is the natural place to
  surface it, and the tier stops being folklore.
- The decode-rate figure itself. Nothing here has been benchmarked; the number
  is upstream's, on upstream's hardware.

## 2. Working-RAM ranges for the large models are extrapolations

`ram_min_mib`/`ram_max_mib` for the 20–26 GiB rows follow the same
weights-plus-overhead-plus-modest-context rule of thumb as the small ones. That
rule was calibrated against models where the whole working set is a few GiB.
Two rows would especially benefit from a real measurement:

- **`gpt-oss:20b` on a 16GB Mac.** It is in the `mac16` tier because MXFP4
  weights are what make a 20B model fit there at all, and it is the only
  catalog entry whose projected minimum (13 GiB) leaves almost nothing for
  macOS. It will assess `CAUTION` on a healthy 16GB machine and `EXCEEDS` under
  any real pressure. If it turns out to be unusable rather than tight, it
  belongs in `mac32` only.
- **`devstral:24b`.** Deliberately *not* in `mac16`: at a 16 GiB projected
  minimum it equals the entire physical RAM of a 16GB Mac, so the tier would
  offer an entry that can never assess better than `CAUTION`. Upstream
  describes it as a 32GB-Mac model. Worth revisiting if a smaller
  quantization tag becomes the default.

## 3. Mixture-of-experts rows may be mis-modeled

`gemma4:26b` (4B active), `qwen3-coder:30b` (3.3B active), and `gpt-oss:20b`
are MoE models: all experts must be resident, but only a fraction are active
per token. The catalog sizes them by resident weights, which is the safe
direction for a fit assessment, but it says nothing about the speed the
operator will actually see. If MoE rows prove much faster than their dense
neighbors of the same footprint, the `notes` column is where that belongs —
the fit columns should stay conservative.

## 4. Tag stability

`models.tsv` pins model *names*, not digests, and Ollama repoints a bare tag
(`gemma4:12b`, `qwen3-coder:30b`) when it republishes. A download size in this
file can therefore go stale without anything in the repo changing.
`check-updates.sh` watches running containers, not the catalog. A small
"re-check catalog sizes against the registry" action would close that gap; it
needs network access from the host and a decision about whether a size drift
should be reported or silently applied.

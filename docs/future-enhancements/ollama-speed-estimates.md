# Ollama Speed Estimates — Replacing the Model with Measurement

**Status:** shipped as estimates, labelled as estimates everywhere they appear.
`environments/ollama/scripts/manage-models.sh` divides a table of per-host
memory-bandwidth figures by each model's `active_gb` to show a tokens/second
figure next to the RAM verdict in the pull menu. Nothing here has been
benchmarked on a host this repo manages. The README states the caveat where it
applies; this file tracks what would retire it.

## Why an estimate was worth shipping at all

The catalog's `mac8` and `pi8` tiers contain a byte-for-byte identical set of
models, because both mean "8 GB". That is correct as a fit judgement and
useless as a usability one: an 8GB M2 runs `qwen3:4b` at conversational speed,
an 8GB Pi 5 runs the same model at walking pace, and the menu said the same
thing about both. A coarse estimate that separates "fast" from "don't bother"
is worth more than silence, provided it never pretends to be a measurement.

## What is actually being computed

Decode is memory-bandwidth bound — each generated token reads the active
weights once — so:

```
tokens/second ≈ effective memory bandwidth (GB/s) ÷ active_gb
```

`active_gb` is a column in `models.tsv`: the download size for a dense model,
and that size scaled by the active/total parameter ratio (plus 0.5 GB for
always-active layers) for a mixture-of-experts model.

Two deliberate conservatisms, both of which understate speed rather than
overstate it:

1. **Only rows whose own `notes` state an active-parameter count are
   discounted.** Today that is `gemma4:26b` (4B of 26B) and `qwen3-coder:30b`
   (3.3B of 30B). `gpt-oss:20b` is described as MoE in
   [`ollama-model-catalog.md`](ollama-model-catalog.md) §3 but carries no ratio
   in its notes, so it is modelled dense and its estimate is pessimistic.
   Adding a ratio to that row's notes is enough to fix it.
2. **An unrecognized host produces no estimate at all**, rather than a fallback
   number that would look exactly as authoritative as a real one.

## What would retire this file

### 1. The bandwidth table is a lookup, and lookups go stale

`_host_bandwidth_gbps()` recognizes Apple Silicon M1–M4 (base/Pro/Max/Ultra)
and Raspberry Pi 4/5, at roughly 80% of each chip's published figure. Every
newer chip falls through to "unknown". `OLLAMA_HOST_BANDWIDTH_GBPS` is the
escape hatch, but it asks the operator for a number they probably do not have.

Better, in rough order of effort:

- A one-off calibration action — generate ~200 tokens from an already-installed
  small model, read the real tok/s out of `ollama run --verbose` or the
  `/api/generate` response's `eval_count`/`eval_duration`, and solve for
  effective bandwidth. That turns the table into a fallback and the *host* into
  the source of truth, which is the right way round.
- Caching that measured figure in the environment's `.env`, so it survives and
  is visible/overridable.
- Falling back to a measured *class* (a short memcpy-style probe) rather than a
  chip name, so an unrecognized chip still gets something.

### 2. The 80% efficiency factor is a single global constant

It was chosen because it lands the estimates close to commonly reported figures
for an M1 with `llama3.2:3b`, an M1 Max with `llama3.1:8b`, and a Pi 5 with
`llama3.2:3b`. It is one number covering CPU inference on a Pi and Metal on a
Mac, which are not alike. Per-platform factors would be better; per-platform
factors derived from measurement would be better still.

### 3. The small-model regime is capped, not modelled

Bandwidth stops being the limit once a model is small enough that per-token
overhead dominates: the formula claims ~230 tok/s for `llama3.2:1b` on an M1
Max, roughly double what one actually does. Rather than publish that, anything
over 100 tok/s displays as `≈100+ tok/s`. That is honest but crude — it is a
refusal to answer, not an answer. A fixed per-token overhead term
(`1 / (active_gb/bw + overhead)`) is the obvious next model, but a single
overhead constant does not fit both ends of the range either; fitting it needs
the measurements in §1.

Embedding models are excluded outright rather than capped, since tokens/second
is not a property they have.

### 4. Ollama's MLX backend on 32GB Macs invalidates the model where it applies

[`ollama-model-catalog.md`](ollama-model-catalog.md) §1 records that Ollama
0.19 moved Apple Silicon inference to MLX with a roughly doubled decode rate
above a 32GB unified-memory floor. If that engages, every `mac32` estimate here
is low by about half — and the estimate has no way to know, because nothing
surfaces which backend served a request. The two files should be resolved
together: whatever answers "which backend is this" also gates the factor.

### 5. Prefill is not modelled

The estimate covers token *generation*. Time-to-first-token on a long prompt is
compute-bound, not bandwidth-bound, and on a Pi it dominates the experience of
a long-context model far more than decode rate does. The catalog's
`long-context` rows are exactly where an operator would be misled by a decode
figure alone. A second, separate figure would be honest; folding prefill into
the existing one would not.

### 6. Per-model context tuning is advice, not configuration

Several catalog rows carry context guidance in prose that nothing enforces:
"keep context short", "the 4GB Pi tier is a stretch with short contexts only",
"keep context modest for headroom". Meanwhile the same rows advertise 128K and
256K context windows, and a consumer that asks for one gets it — the daemon
tuning added alongside these estimates governs how many models stay resident,
not how much context each is allowed.

Making that real means a per-model, per-tier `num_ctx`, which in Ollama means
generating a `Modelfile` and creating a derived tag at pull time. That is a
larger change than it sounds: it puts a repo-generated artifact between the
operator and the upstream tag, and this repo has learned twice over what a
generated artifact nobody rebuilds costs (see `CLAUDE.md` on version-marked
patches and derived images). It should not be built until someone actually
wants it.

### 7. Quantization is not selectable

`models.tsv` pins one tag per model, so `active_gb` describes whatever
quantization that tag currently resolves to. An operator who wants `q8_0` on a
32GB Mac, or a smaller quant to fit a Pi at all, has no way to express it and
would get an estimate for the wrong artifact. This is the same tag-stability
problem as [`ollama-model-catalog.md`](ollama-model-catalog.md) §4, and any
per-quantization rows added there need an `active_gb` each.

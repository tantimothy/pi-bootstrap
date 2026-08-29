# Ollama Model Hardware and Use-Case Matrix

This pivot-style matrix is generated from [`models.tsv`](models.tsv).
Each model appears once, grouped by the minimum hardware tier that
introduces it. Read from top to bottom to see what additional RAM unlocks.
Usage columns mirror the **Pull a Recommended Model → Suggested use** menu.

A checkmark means the supplied model articles recommend that model for
the use case. Models in a lower tier remain available to the higher tiers.
Hardware membership is planning guidance rather than a guarantee; the live
pull assessment also considers available RAM and memory pressure.

| Model | Wiki | Embeddings | General | Coding | Reasoning | Fast | Multilingual | Long context | Description |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|---|
| **Raspberry Pi 4/5 — 4 GB baseline** | | | | | | | | | |
| `nomic-embed-text` | ✓ | ✓ |  |  |  |  |  |  | Mnemon/RAG embeddings only; not a chat model |
| `llama3.2:1b` |  |  | ✓ |  |  | ✓ |  |  | Small general chat; fastest Llama option on Raspberry Pi |
| `qwen2.5:1.5b` |  |  | ✓ |  |  | ✓ | ✓ |  | Fast multilingual chat with low memory use |
| `qwen3:1.7b` |  |  | ✓ |  |  | ✓ | ✓ |  | Extremely fast small multilingual model |
| `qwen3.5:2b` | ✓ |  | ✓ |  |  |  | ✓ | ✓ | 256K context; the 4GB Pi tier is a stretch with short contexts only |
| `deepseek-r1:1.5b` |  |  |  |  | ✓ | ✓ |  |  | CPU-friendly lightweight chain-of-thought reasoning |
| **Apple Silicon Mac or Raspberry Pi 4/5 — 8 GB additions** | | | | | | | | | |
| `llama3.2:3b` | ✓ |  | ✓ |  |  |  |  |  | Balanced general chat, writing, summaries, and wiki Q&A |
| `qwen2.5:3b` |  |  | ✓ |  |  |  | ✓ |  | Balanced multilingual chat for an 8GB Raspberry Pi |
| `qwen3:4b` |  |  | ✓ |  | ✓ |  | ✓ |  | Strong intelligence/speed balance; tight on an 8GB Mac or Pi |
| `qwen3.5:4b` | ✓ |  | ✓ |  | ✓ |  | ✓ | ✓ | 256K context; useful for wiki and agent-style work |
| `gemma4:e2b-it-qat` |  |  | ✓ |  | ✓ |  |  | ✓ | 128K context; quantization-aware training replaces gemma3:4b in a smaller download |
| `phi4-mini` | ✓ |  |  |  | ✓ |  |  | ✓ | 128K context; strong grounded wiki Q&A, math, and logic |
| **Apple Silicon Mac — 16 GB additions** | | | | | | | | | |
| `qwen3:8b` |  |  | ✓ |  | ✓ |  | ✓ |  | General-purpose 16GB Mac pick with strong multilingual ability |
| `qwen3.5:9b` |  |  | ✓ |  | ✓ |  | ✓ | ✓ | High-quality 16GB Mac option; keep context modest for headroom |
| `gemma4:e4b` | ✓ |  |  |  | ✓ |  |  | ✓ | 128K context, tool calling, and agent logic; tight on 16GB, so keep context short |
| `gemma4:12b` |  |  | ✓ |  | ✓ |  |  | ✓ | 256K context; replaces gemma3:12b with a smaller download and a longer context |
| `qwen2.5-coder:7b` |  |  |  | ✓ |  |  |  |  | Code generation, reasoning, and fixes on a 16GB Mac |
| `gpt-oss:20b` |  |  |  | ✓ |  |  |  | ✓ | 128K context; MXFP4 weights make it the largest coding model that still fits 16GB, so keep context short |
| `deepseek-r1:8b` |  |  |  |  | ✓ |  |  |  | Reasoning and math for a 16GB Mac |
| `llama3.1:8b` | ✓ |  | ✓ |  |  |  |  |  | Stable all-rounder for chat, summaries, and structured formatting |
| **Apple Silicon Mac — 32 GB additions** | | | | | | | | | |
| `qwen3.8:27b` |  |  | ✓ |  | ✓ |  | ✓ | ✓ | 256K context and image input; the general-purpose pick once 32GB is available |
| `gemma4:26b` |  |  | ✓ |  | ✓ |  |  | ✓ | 256K context; mixture-of-experts with 4B active parameters, so it decodes faster than its size suggests |
| `devstral:24b` |  |  |  | ✓ |  |  |  | ✓ | 128K context; agentic coding tuned, 46.8% SWE-Bench Verified; needs the 32GB tier |
| `qwen3-coder:30b` |  |  |  | ✓ | ✓ |  |  | ✓ | 256K context; mixture-of-experts with 3.3B active parameters for repository-scale work |
| `deepseek-r1:32b` |  |  |  |  | ✓ |  |  | ✓ | 128K context; the strongest local reasoning model the 32GB tier can hold |

# Ollama Model Hardware and Use-Case Matrix

This pivot-style matrix is generated from [`models.tsv`](models.tsv).
Each model appears once, grouped by the minimum hardware tier that
introduces it. Read from top to bottom to see what additional RAM unlocks.
Usage columns mirror the **Pull a Recommended Model → Suggested use** menu.

A checkmark means the supplied model articles recommend that model for
the use case. Models in a lower tier remain available to the higher tiers.
Hardware membership is planning guidance rather than a guarantee; the live
pull assessment also considers available RAM and memory pressure.

| Model | Wiki | Embeddings | General | Coding | Reasoning | Fast | Multilingual | Long context |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **Raspberry Pi 4/5 — 4 GB baseline** | | | | | | | | |
| `nomic-embed-text` | ✓ | ✓ |  |  |  |  |  |  |
| `llama3.2:1b` |  |  | ✓ |  |  | ✓ |  |  |
| `qwen2.5:1.5b` |  |  | ✓ |  |  | ✓ | ✓ |  |
| `qwen3:1.7b` |  |  | ✓ |  |  | ✓ | ✓ |  |
| `qwen3.5:2b` | ✓ |  | ✓ |  |  |  | ✓ | ✓ |
| `gemma3:1b` |  |  | ✓ |  |  | ✓ |  |  |
| `deepseek-r1:1.5b` |  |  |  |  | ✓ | ✓ |  |  |
| **Apple Silicon Mac or Raspberry Pi 4/5 — 8 GB additions** | | | | | | | | |
| `llama3.2:3b` | ✓ |  | ✓ |  |  |  |  |  |
| `qwen2.5:3b` |  |  | ✓ |  |  |  | ✓ |  |
| `qwen3:4b` |  |  | ✓ |  | ✓ |  | ✓ |  |
| `qwen3.5:4b` | ✓ |  | ✓ |  | ✓ |  | ✓ | ✓ |
| `gemma3:4b` | ✓ |  | ✓ |  | ✓ |  |  | ✓ |
| `phi3:mini` |  |  | ✓ |  |  | ✓ |  |  |
| `phi4-mini` | ✓ |  |  |  | ✓ |  |  | ✓ |
| **Apple Silicon Mac — 16 GB additions** | | | | | | | | |
| `qwen3:8b` |  |  | ✓ |  | ✓ |  | ✓ |  |
| `qwen3.5:9b` |  |  | ✓ |  | ✓ |  | ✓ | ✓ |
| `gemma3:12b` |  |  | ✓ |  | ✓ |  |  | ✓ |
| `gemma4:e4b` | ✓ |  |  |  | ✓ |  |  | ✓ |
| `qwen2.5-coder:7b` |  |  |  | ✓ |  |  |  |  |
| `deepseek-r1:8b` |  |  |  |  | ✓ |  |  |  |
| `llama3.1:8b` | ✓ |  | ✓ |  |  |  |  |  |

# Ollama Model Hardware and Use-Case Matrix

This pivot-style matrix is generated from [`models.tsv`](models.tsv).
Models are grouped by supported RAM/machine tier; usage columns mirror
the **Pull a Recommended Model → Suggested use** menu.

A checkmark means the supplied model articles recommend that model for
the use case. Hardware membership is planning guidance rather than a
guarantee; the live pull assessment also considers available RAM and
memory pressure.

## Apple Silicon Mac — 16 GB

| Model | Wiki | Embeddings | General | Coding | Reasoning | Fast | Multilingual | Long context |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `nomic-embed-text` | ✓ | ✓ |  |  |  |  |  |  |
| `llama3.2:1b` |  |  | ✓ |  |  | ✓ |  |  |
| `llama3.2:3b` | ✓ |  | ✓ |  |  |  |  |  |
| `qwen2.5:1.5b` |  |  | ✓ |  |  | ✓ | ✓ |  |
| `qwen2.5:3b` |  |  | ✓ |  |  |  | ✓ |  |
| `qwen3:1.7b` |  |  | ✓ |  |  | ✓ | ✓ |  |
| `qwen3:4b` |  |  | ✓ |  | ✓ |  | ✓ |  |
| `qwen3:8b` |  |  | ✓ |  | ✓ |  | ✓ |  |
| `qwen3.5:2b` | ✓ |  | ✓ |  |  |  | ✓ | ✓ |
| `qwen3.5:4b` | ✓ |  | ✓ |  | ✓ |  | ✓ | ✓ |
| `qwen3.5:9b` |  |  | ✓ |  | ✓ |  | ✓ | ✓ |
| `gemma3:1b` |  |  | ✓ |  |  | ✓ |  |  |
| `gemma3:4b` | ✓ |  | ✓ |  | ✓ |  |  | ✓ |
| `gemma3:12b` |  |  | ✓ |  | ✓ |  |  | ✓ |
| `gemma4:e4b` | ✓ |  |  |  | ✓ |  |  | ✓ |
| `phi3:mini` |  |  | ✓ |  |  | ✓ |  |  |
| `phi4-mini` | ✓ |  |  |  | ✓ |  |  | ✓ |
| `qwen2.5-coder:7b` |  |  |  | ✓ |  |  |  |  |
| `deepseek-r1:1.5b` |  |  |  |  | ✓ | ✓ |  |  |
| `deepseek-r1:8b` |  |  |  |  | ✓ |  |  |  |
| `llama3.1:8b` | ✓ |  | ✓ |  |  |  |  |  |

## Apple Silicon Mac — 8 GB

| Model | Wiki | Embeddings | General | Coding | Reasoning | Fast | Multilingual | Long context |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `nomic-embed-text` | ✓ | ✓ |  |  |  |  |  |  |
| `llama3.2:1b` |  |  | ✓ |  |  | ✓ |  |  |
| `llama3.2:3b` | ✓ |  | ✓ |  |  |  |  |  |
| `qwen2.5:1.5b` |  |  | ✓ |  |  | ✓ | ✓ |  |
| `qwen2.5:3b` |  |  | ✓ |  |  |  | ✓ |  |
| `qwen3:1.7b` |  |  | ✓ |  |  | ✓ | ✓ |  |
| `qwen3:4b` |  |  | ✓ |  | ✓ |  | ✓ |  |
| `qwen3.5:2b` | ✓ |  | ✓ |  |  |  | ✓ | ✓ |
| `qwen3.5:4b` | ✓ |  | ✓ |  | ✓ |  | ✓ | ✓ |
| `gemma3:1b` |  |  | ✓ |  |  | ✓ |  |  |
| `gemma3:4b` | ✓ |  | ✓ |  | ✓ |  |  | ✓ |
| `phi3:mini` |  |  | ✓ |  |  | ✓ |  |  |
| `phi4-mini` | ✓ |  |  |  | ✓ |  |  | ✓ |
| `deepseek-r1:1.5b` |  |  |  |  | ✓ | ✓ |  |  |

## Raspberry Pi 4/5 — 8 GB

| Model | Wiki | Embeddings | General | Coding | Reasoning | Fast | Multilingual | Long context |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `nomic-embed-text` | ✓ | ✓ |  |  |  |  |  |  |
| `llama3.2:1b` |  |  | ✓ |  |  | ✓ |  |  |
| `llama3.2:3b` | ✓ |  | ✓ |  |  |  |  |  |
| `qwen2.5:1.5b` |  |  | ✓ |  |  | ✓ | ✓ |  |
| `qwen2.5:3b` |  |  | ✓ |  |  |  | ✓ |  |
| `qwen3:1.7b` |  |  | ✓ |  |  | ✓ | ✓ |  |
| `qwen3:4b` |  |  | ✓ |  | ✓ |  | ✓ |  |
| `qwen3.5:2b` | ✓ |  | ✓ |  |  |  | ✓ | ✓ |
| `qwen3.5:4b` | ✓ |  | ✓ |  | ✓ |  | ✓ | ✓ |
| `gemma3:1b` |  |  | ✓ |  |  | ✓ |  |  |
| `gemma3:4b` | ✓ |  | ✓ |  | ✓ |  |  | ✓ |
| `phi3:mini` |  |  | ✓ |  |  | ✓ |  |  |
| `phi4-mini` | ✓ |  |  |  | ✓ |  |  | ✓ |
| `deepseek-r1:1.5b` |  |  |  |  | ✓ | ✓ |  |  |

## Raspberry Pi 4/5 — 4 GB

| Model | Wiki | Embeddings | General | Coding | Reasoning | Fast | Multilingual | Long context |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `nomic-embed-text` | ✓ | ✓ |  |  |  |  |  |  |
| `llama3.2:1b` |  |  | ✓ |  |  | ✓ |  |  |
| `qwen2.5:1.5b` |  |  | ✓ |  |  | ✓ | ✓ |  |
| `qwen3:1.7b` |  |  | ✓ |  |  | ✓ | ✓ |  |
| `qwen3.5:2b` | ✓ |  | ✓ |  |  |  | ✓ | ✓ |
| `gemma3:1b` |  |  | ✓ |  |  | ✓ |  |  |
| `deepseek-r1:1.5b` |  |  |  |  | ✓ | ✓ |  |  |

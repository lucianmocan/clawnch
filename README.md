# Clawnch

The goal of this tool is to use SoTA practices for safe & secure AI agent tooling usage (to some extent).

Initial support for macOS + [opencode](https://github.com/anomalyco/opencode).

## Requirements

- macOS
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [just](https://github.com/casey/just) (`brew install just`)

## Quick start

```sh
# 1. Store your API keys (saved to macOS Keychain, never to disk as plaintext)
just setup

# 2. Build the sandboxed image
just build

# 3. Run the agent against a project folder
just opencode ~/my-project
```

The container runs as a non-root user, drops all Linux capabilities, and mounts only the target folder.

## Commands

| Command | Description |
|---|---|
| `just build` | Build the Docker image |
| `just setup` | Store API keys in macOS Keychain |
| `just list` | List stored keys (values masked) |
| `just remove-key <KEY>` | Remove a key from Keychain |
| `just opencode <folder> [args...]` | Run opencode against a folder |
| `just opencode <folder> net=none` | Run fully isolated (no network; AI features unavailable) |

## Security notes

- API keys are read directly from Keychain into the container via a pipe — they are never written to disk.
- The Docker image pins both the base image and the opencode binary to a specific version and verifies the SHA-256 checksum at build time.
- To update opencode, bump `OPENCODE_VERSION` and the corresponding `OPENCODE_SHA256_*` ARGs in the Dockerfile.

## Roadmap

- [ ] **Egress proxy / network allowlisting** — allow the container to reach only known AI provider endpoints (Anthropic, OpenAI, OpenRouter, etc.) while blocking everything else
- [ ] **Additional agents** — support for [Claude Code](https://github.com/anthropics/claude-code) (`claude`), [OpenAI Codex CLI](https://github.com/openai/codex) (`codex`), [Gemini CLI](https://github.com/google-gemini/gemini-cli), and others via per-agent Dockerfile targets
- [ ] **Linux support** — replace macOS Keychain with a cross-platform secrets backend (e.g. `pass`, environment variables, or a secrets manager)
- [ ] **Capability fine-tuning** — flags to selectively restore dropped Linux capabilities for agents that need them (e.g. `caps=net_raw,sys_ptrace`); current default drops all

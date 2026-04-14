# DevContainer Bootstrap

`bootstrap.sh` generates a baseline Dev Container setup for new or existing workspaces.
It focuses on reproducible setup, multi-account GitHub switching, and AI coding tooling.

This guide explains:
- what will be generated,
- which inputs are required,
- and what to verify after generation.

Recommended approach:
- start with the minimum command,
- then add language and template options as needed.

This package assumes development workflows with AI coding tools (Copilot, Claude, Gemini, etc.).
It emphasizes multi-account GitHub switching, CLI authentication state verification, and reproducible initial setup.

## Public Release Usage

Public repository:
- https://github.com/ojos/devcontainer-bootstrap

Latest stable release:
- `v0.1.6`

## Quick Start

```bash
TAG=v0.1.6
curl -sSL "https://github.com/ojos/devcontainer-bootstrap/releases/download/${TAG}/bootstrap.sh" -o bootstrap.sh
curl -sSL "https://github.com/ojos/devcontainer-bootstrap/releases/download/${TAG}/SHA256SUMS" -o SHA256SUMS
sha256sum -c SHA256SUMS
bash bootstrap.sh --project-name myapp --languages node,go --mode standard
```

---

## Input Specification

### Required Inputs
- `--project-name <name>` (string, required)
- `--languages <csv>` (CSV format. Choose from `node`, `go`, `python`. Required.)
- `--mode <minimal|standard|full>` (template selection. Default: `standard`)

### Optional Inputs
- `--output-dir <path>` (default: creates `<project-name>/` in current directory)
- `--base-image <image>` (override auto-detected base image)
- `--github-profiles <csv>` (GitHub profiles for multi-account env injection. Default: `primary,secondary`)

---

## Supported Languages

Supported runtimes (any combination):
- `node` (Node.js / JavaScript / TypeScript)
- `go` (Go)
- `python` (Python 3)

### Examples:
```bash
# Single language
./bootstrap.sh --project-name myapp --languages node --mode minimal

# Multiple languages
./bootstrap.sh --project-name myapp --languages node,go,python --mode standard

# Backend only
./bootstrap.sh --project-name backend-api --languages go,python --mode minimal

# With explicit output directory
./bootstrap.sh --project-name myapp --languages node --mode standard --output-dir /path/to/existing-workspace

# Without .gitignore managed section update
./bootstrap.sh --project-name myapp --languages node --mode minimal --no-gitignore

# macOS + language-specific templates only
./bootstrap.sh --project-name myapp --languages node,python --mode standard

# Add custom gitignore templates
./bootstrap.sh --project-name myapp --languages node --mode standard --gitignore-targets macOS,Node,VisualStudioCode

# Specify GitHub profiles
./bootstrap.sh --project-name myapp --languages node --mode full --github-profiles work,personal
```

After generation, you can switch profiles:

```bash
bash scripts/github-account-switch.sh list
bash scripts/github-account-switch.sh use ojos
```

---

## Feature Flags
- `features.docker` (default: true)
- `features.githubCli` (default: true)
- `features.node` (when `languages` includes `node`)
- `features.go` (when `languages` includes `go`)
- `features.python` (when `languages` includes `python`)
- `features.awsCli` (full mode only)
- `features.devTools` (default: true)

---

## Secret Management

Secrets are injected as environment variable names only (never as literal values).
This approach prevents credentials from being leaked in repository files while enabling safe authentication switching for AI coding.

- `GITHUB_TOKEN_<PROFILE>` (e.g., `GITHUB_TOKEN_WORK`, `GITHUB_TOKEN_PERSONAL`)
  - Token for `gh` CLI authentication when switching to `<PROFILE>`.
- `GITHUB_OWNER_<PROFILE>` (optional, if token issuer differs from target owner)
  - Owner (personal account or organization) to use for `github.owner` when switching to `<PROFILE>`.
- `GIT_AUTHOR_NAME_<PROFILE>` (optional)
  - Commit author name to set in `git config user.name` when switching to `<PROFILE>`.
- `GIT_AUTHOR_EMAIL_<PROFILE>` (optional)
  - Commit author email to set in `git config user.email` when switching to `<PROFILE>`.
- `CLAUDE_CODE_OAUTH_TOKEN`
  - OAuth token for Claude CLI.
- `GEMINI_API_KEY`
  - API key for Gemini CLI.

The generated devcontainer configuration uses only `${localEnv:...}` references and never stores secrets in files.
Avoid permanently setting `GH_TOKEN` in environment, as it interferes with multi-account switching.

Notes:
- `GITHUB_TOKEN_<PROFILE>` is used by `scripts/github-account-switch.sh` for profile-based switching.
- `GITHUB_OWNER_<PROFILE>` is needed only when the token issuer and target owner differ.

---

## Validation Rules
1. `languages` must include at least one of `node`, `go`, or `python`
2. Each specified language must have a corresponding feature in devcontainer.json
3. Each profile in `--github-profiles` must generate `GITHUB_TOKEN_<PROFILE>` and related `remoteEnv` entries
4. Base image is auto-detected from Docker server `os/arch` (default: `mcr.microsoft.com/devcontainers/base:ubuntu`, override with `--base-image`)

---

## Expected Output
- `.devcontainer/devcontainer.json` (with language-specific features)
- `scripts/github-account-switch.sh`
- `scripts/on-attach.sh`
- `scripts/post-rebuild-check.sh`
- `.gitignore` managed section (updated based on languages)
- README setup section (updated)

### `.gitignore` and github/gitignore Integration
- The managed section always includes `github/gitignore` templates at the end.
- Default targets: `macOS` + language-specific templates (`node`→`Node`, `go`→`Go`, `python`→`Python`)
- `--gitignore-targets <csv>` adds to the defaults (duplicates removed).
- Templates are fetched from `https://github.com/github/gitignore` (searches for both `<name>.gitignore` and `Global/<name>.gitignore`).
- Missing templates generate a warning but do not stop processing.

> **Note**: `--languages` values are lowercase (`node`, `go`, `python`), while `--gitignore-targets` values match [github/gitignore](https://github.com/github/gitignore) filenames (capitalized: `Node`, `Go`, `macOS`). This difference is intentional.

---

## Doctor Self-Check

After generation, run:
```bash
./doctor.sh --target-dir result --strict
```

This validates that each configured language runtime is available.

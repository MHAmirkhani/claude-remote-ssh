# Contributing to claude-remote-ssh

Thank you for considering a contribution. This project exists to help researchers, students, and engineers work with servers that would otherwise be unreachable. Every improvement — a bug fix, a new platform, a documentation correction — helps someone in a similar situation.

---

## Table of Contents

1. [Code of Conduct](#code-of-conduct)
2. [Ways to Contribute](#ways-to-contribute)
3. [Development Workflow](#development-workflow)
4. [Style Guidelines](#style-guidelines)
5. [Testing Requirements](#testing-requirements)
6. [Secret Hygiene](#secret-hygiene)
7. [Pull Request Process](#pull-request-process)
8. [Commit Message Conventions](#commit-message-conventions)
9. [License](#license)

---

## Code of Conduct

Be respectful. This project serves users in restricted network environments — some of whom may be under significant personal risk. Do not ask for or share:

- Real Gist URLs with tokens
- Working proxy endpoints
- SSH private keys
- Any identifying information about a user's network

Reports that violate this will be deleted without discussion.

---

## Ways to Contribute

### High-value contributions

- **New platform installers** — Fedora, Arch, Alpine, FreeBSD
- **Alternative tunnel backends** — `localhost.run`, `serveo.net`, `ngrok`, self-hosted FRP
- **Client ports** — A native macOS menu bar app, or a systemd user service for Linux
- **Documentation translations** — Persian (Farsi), Arabic, Russian, Chinese
- **Bug fixes** — Especially around network edge cases and error handling

### Small contributions

- Fixing typos in `docs/`
- Improving error messages
- Adding examples to the troubleshooting guide
- Reporting reproducible bugs with detailed logs

### Not accepted

- Changes that remove security checks (e.g., disabling `StrictHostKeyChecking` entirely)
- Hardcoded credentials, even in examples
- Features that require a paid service with no free alternative
- Anything that could be used to bypass authorization on third-party systems

---

## Development Workflow

### 1. Fork and clone

```bash
git clone https://github.com/YOUR_USERNAME/claude-remote-ssh.git
cd claude-remote-ssh
git remote add upstream https://github.com/MHAmirkhani/claude-remote-ssh.git
```

### 2. Create a feature branch

Use a descriptive name:

```bash
git checkout -b feature/fedora-installer
git checkout -b fix/gist-timeout-retry
git checkout -b docs/translate-persian
```

### 3. Make your changes

- Keep commits focused on one logical change.
- Update documentation alongside code changes.
- Add an entry to `CHANGELOG.md` under `[Unreleased]`.

### 4. Test locally

Before pushing, verify:

- Shell scripts pass `shellcheck`
- JSON files parse
- PowerShell passes `PSScriptAnalyzer`
- No secrets are present

See [Testing Requirements](#testing-requirements) for details.

### 5. Push and open a PR

```bash
git push origin feature/fedora-installer
```

Then open a pull request against `main`.

---

## Style Guidelines

### Shell scripts (`.sh`)

- Target **POSIX Bash 4.0+** (not POSIX `sh`).
- Start every script with `#!/usr/bin/env bash`.
- Use `set -euo pipefail` unless the script has a specific reason not to.
- Quote all variable expansions: `"$VAR"` — always.
- Use `[[ ]]` for conditionals, not `[ ]`.
- Use `$(...)` for command substitution, not backticks.
- Define functions with `function_name() { ... }`.
- Use lowercase for local variables, `UPPER_CASE` for constants and exported vars.
- Log with a helper function (e.g., `log()`, `warn()`, `err()`) rather than raw `echo`.

**Example:**

```bash
#!/usr/bin/env bash
set -euo pipefail

log() { echo "[+] $*"; }
err() { echo "[x] $*" >&2; }

main() {
    local target="${1:-default}"
    if [[ -z "$target" ]]; then
        err "Target is required."
        exit 1
    fi
    log "Processing $target"
}

main "$@"
```

### PowerShell scripts (`.ps1`)

- Use `[CmdletBinding()]` on non-trivial scripts.
- Set `$ErrorActionPreference = "Stop"` at the top.
- Avoid `Write-Host` where possible — use `Write-Output`, `Write-Warning`, `Write-Error`.
  - Exception: interactive installers where colored output matters.
- Prefer `[PSCustomObject]` over `New-Object`.
- Use `[System.IO.File]::WriteAllText()` for UTF-8 without BOM — the built-in `Set-Content` adds a BOM on PS 5.1, which breaks JSON parsers.
- Support both **Windows PowerShell 5.1** and **PowerShell 7+**. Test both if you can.

**Example:**

```powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Target = "default"
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message)
    Write-Host "[+] $Message" -ForegroundColor Green
}

Write-Log "Processing $Target"
```

### JSON files

- 2-space indentation.
- No trailing commas.
- Sort keys logically (metadata first, then content).
- Validate with `python -m json.tool <file>` before committing.

### Markdown

- One sentence per line (makes diffs cleaner).
- Use ATX headings (`#`, `##`, not `===` or `---`).
- Fenced code blocks with language tags: ` ```bash `, ` ```powershell `, ` ```json `.
- Relative links for internal docs: `[02 — Server Setup](02-server-setup.md)`.
- Absolute links for external resources.

---

## Testing Requirements

### Mandatory before PR

All shell scripts must pass `shellcheck` with zero warnings:

```bash
sudo apt install shellcheck    # or brew install shellcheck
shellcheck server/*.sh client-unix/*.sh
```

All JSON must parse:

```bash
for f in server/*.json desktop-windows/*.json; do
    python3 -m json.tool "$f" > /dev/null || echo "FAIL: $f"
done
```

PowerShell scripts must pass `PSScriptAnalyzer`:

```powershell
Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser
Invoke-ScriptAnalyzer -Path .\desktop-windows -Recurse -Severity Warning,Error
```

### Recommended

If you can, run the full end-to-end test on a VM:

1. Fresh Ubuntu 22.04 with `sudo`
2. Working VLESS subscription
3. Test Gist + token
4. Run `setup-server.sh`
5. Verify `check-tunnel` shows all green
6. Complete the desktop flow

Include your test environment details in the PR description.

### CI

GitHub Actions runs four jobs on every push:

| Job | Purpose |
|---|---|
| `shellcheck` | Lint all `.sh` files |
| `json-lint` | Validate JSON syntax |
| `powershell-lint` | PSScriptAnalyzer on `.ps1` files |
| `secrets-scan` | Fail if `ghp_*` patterns are committed |

Your PR will not be merged if any of these fail.

---

## Secret Hygiene

### Never commit

- GitHub Personal Access Tokens (`ghp_*`, `github_pat_*`)
- SSH private keys (`id_ed25519`, `id_rsa`, `*.pem`)
- VLESS / Trojan URLs with real UUIDs
- Actual Gist IDs from private accounts
- Server hostnames or IPs from real deployments

### Use placeholders in examples

```bash
# Good
GITHUB_TOKEN="YOUR_GITHUB_TOKEN_HERE"
GIST_ID="YOUR_GIST_ID_HERE"
VLESS_URL="vless://UUID@HOST:PORT?params#label"

# Bad
GITHUB_TOKEN="ghp_abc123..."
GIST_ID="051d822078a8681de42c8a1c38d25fcb"
```

### If you accidentally commit a secret

1. **Revoke it immediately** — before doing anything else.
2. Generate a replacement.
3. Remove it from git history:
   ```bash
   git filter-repo --path path/to/leaked/file --invert-paths
   # or, for a single line:
   git filter-repo --replace-text <(echo "ghp_REAL_TOKEN==>ghp_REDACTED")
   ```
4. Force push (`git push --force-with-lease`).
5. Note in your PR that a secret was rotated.

Do **not** rely on `git rm` alone — the secret remains in the history.

---

## Pull Request Process

### Before opening

- [ ] Branch is based on the latest `main`
- [ ] Changes are focused on a single logical topic
- [ ] Commits have descriptive messages (see [conventions](#commit-message-conventions))
- [ ] `CHANGELOG.md` has a new entry under `[Unreleased]`
- [ ] Documentation is updated if behavior changed
- [ ] All CI checks pass locally
- [ ] No secrets are present

### PR description template

```markdown
## Summary
One-paragraph description of what this PR does and why.

## Motivation
The problem this solves, or the use case it enables.

## Test Plan
- [ ] Ran `shellcheck` locally
- [ ] Validated JSON with `python3 -m json.tool`
- [ ] Tested on Ubuntu 22.04 with Xray v25.9.11
- [ ] End-to-end pipeline verified (optional)

## Environment
- OS: Ubuntu 22.04
- Node.js: v20.10.0
- Claude Desktop: 0.10.2

## Screenshots / Logs
(optional)
```

### Review process

1. A maintainer will review within ~5 days.
2. Feedback will be posted as inline comments.
3. Push follow-up commits to the same branch (don't force-push after review starts unless asked).
4. Once approved, the PR will be squashed and merged into `main`.

### What gets rejected

- Changes that break the "no VPS" guarantee without a compelling reason
- New dependencies that don't have a clear justification
- Style-only changes without a functional improvement
- Any code that could be used to access third-party systems without authorization

---

## Commit Message Conventions

Follow the [Conventional Commits](https://www.conventionalcommits.org/) format:

```
<type>(<scope>): <subject>

<body>

<footer>
```

### Types

| Type | Use for |
|---|---|
| `feat` | A new feature |
| `fix` | A bug fix |
| `docs` | Documentation only |
| `style` | Formatting, no code change |
| `refactor` | Code change that isn't a fix or feature |
| `test` | Adding or fixing tests |
| `chore` | Build, CI, dependency updates |
| `security` | Security-related changes |

### Scopes

Use the affected component: `server`, `desktop-windows`, `client-unix`, `docs`, `ci`.

### Examples

```
feat(server): add DNS health check to watchdog

The previous watchdog only checked `kill -0`, which returns success
even when the Pinggy endpoint has expired. This adds a DNS resolution
check every 90 seconds to detect zombie tunnels.

Closes #42
```

```
fix(desktop-windows): support PowerShell 5.1

Removed use of `-AsHashtable` which is only available in PS 6+.
The config is now manipulated via `[PSCustomObject]` and `Add-Member`,
which work in both 5.1 and 7+.

Fixes #58
```

```
docs(troubleshooting): add zombie tunnel diagnostic

Added a new section covering the case where the tunnel process is
alive but DNS no longer resolves. Includes the `check-tunnel` command
and manual restart instructions.
```

---

## License

By submitting a pull request, you agree that your contributions will be licensed under the [MIT License](LICENSE).

---

## Questions?

Open a [GitHub Discussion](https://github.com/MHAmirkhani/claude-remote-ssh/discussions) or file an [issue](https://github.com/MHAmirkhani/claude-remote-ssh/issues).

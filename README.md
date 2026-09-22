# Ralph

Resolves GitHub issues without supervision, using two agents and a real gate:

```
Codex (gpt-6-luna, max)                implements with the tdd skill  →  opens PR
Claude (opus, medium)                  returns the review              →  PASS ? merge : Codex fixes
Codex                                 fixes on the same branch       →  Claude reviews again
```

**Nothing is merged without an explicit `<verdict>PASS</verdict>` from Claude.** If
the PR still does not pass after 3 review rounds, it remains open and is labeled
`ralph-needs-human`: the loop never merges out of exhaustion, and does not touch
that PR again in later runs.

Each agent's real exit code is preserved before its output is passed through
`tee`: an agent that ends with an error can never become PASS. The verdict is
accepted only when it is the last line of Claude's final output; a `tee` failure
returns 70 and stops the run.

The review, checks, and merge stay tied to the same SHA: Ralph compares the
local `HEAD` with `headRefOid` before and after reviewing, requires a clean tree,
and uses `--match-head-commit` when merging. If GitHub takes time to reflect a
newly pushed commit, it retries `headRefOid` up to 5 times, waiting 2 seconds
between reads; a different local `HEAD` fails immediately, and Ralph never
reviews or merges a SHA that the PR does not confirm. `RALPH_MERGE_METHOD` only
accepts `--squash`, `--merge`, or `--rebase`; any other value stops preflight.

## CI

The CI policy is `required` by default. Ralph distinguishes three states:

- **Red CI:** a check finished with a failure after running steps. Ralph leaves
  the details on the PR for Codex to fix; it does not merge.
- **Pending CI:** checks are missing or remain `queued`/`in_progress`. Ralph
  waits up to `RALPH_CI_TIMEOUT_SECONDS` (30 minutes by default), leaves the
  issue in `ci_pending`, and does not send a fix or merge.
- **Infrastructure (`ci_infrastructure`):** a job ended in `failure` or
  `cancelled` without running steps, or its annotation says it was not started
  (for example, because of billing or a spending limit). Ralph retries polling
  up to `RALPH_MAX_INFRA_RETRIES`, without consuming a round or commenting on
  red CI; if it persists, it stops the run with rc 70. The message cites the
  annotation and the command `gh api repos/<slug>/check-runs/<id>/annotations`,
  and the reason is recorded in `RUN_DIR/summary.json`.

Before querying issues, preflight inspects the base branch's latest CI run and
requires it to have run at least one step. If it did not start because of that
infrastructure problem, the run fails with `ci_infrastructure`. For repositories
without CI, `RALPH_CI_POLICY=none` is an explicit exception and is reported in
the output.

Each run calculates a global deadline at startup: `RALPH_MAX_RUN_SECONDS` (4
hours by default). It also limits the number of unique issues started to
`RALPH_MAX_ISSUES` (5 by default); limit retries do not consume another slot.
When either limit expires, Ralph saves a checkpoint, ends without starting
another agent or merging, and records `stop_reason=deadline` or
`stop_reason=max_issues`. CI and provider reset waits are bounded by the same
deadline. Preflight requires a GNU implementation of `timeout`: it chooses
`gtimeout` when available (Homebrew `coreutils` on macOS), then `timeout` on
Linux; if neither is usable, it stops the run with installation instructions.

`RALPH_CLAUDE_MAX_BUDGET_USD` adds `--max-budget-usd` to every Claude
invocation, including the smoke test. `RALPH_RUN_BUDGET_USD` is an estimated
Claude cost cap for the entire run: when Claude's reported accumulated cost
reaches or exceeds it, Ralph does not start another agent and records
`stop_reason=budget`. It is not an exact billing measurement or a shared Claude
and Codex budget; Codex's hard ceiling is configured with its provider.

The project can declare its gates with
`RALPH_REQUIRED_CHECKS_JSON='["CI / test","ShellCheck"]'`. Ralph queries the
`check-runs` and `statuses` for the exact SHA Claude reviewed: every declared
name must end in `success`; `skipped`, `neutral`, `cancelled`, `pending`, and
missing results do not enable a merge. Additional successful checks do not
replace a required one. If the list is not declared, all results for the SHA
must be successful and at least one must exist.

Base branch protection is also `required` by default:
`RALPH_REQUIRE_PROTECTION=1` queries the active rulesets for the base branch,
checks that they cover the checks in `RALPH_REQUIRED_CHECKS_JSON`, and rejects
any bypass for the merging identity. If a separate reviewer identity is
configured with `RALPH_REVIEW_IDENTITY`, the ruleset must require an approval or
the `ralph-review` check; before merging, that approval or check must match the
reviewed SHA and that identity. `RALPH_REQUIRE_PROTECTION=0` is reserved for
the test sandbox, is explicitly reported, and is recorded in
`RUN_DIR/summary.json`. Omitting `--auto` does not disable this protection:
immediate merging still follows the server's applicable rules.

After requesting the merge, Ralph polls the PR until it confirms `state=MERGED`
with a valid `mergeCommit.oid` SHA. The timeout is 10 minutes by default and is
configured with `RALPH_MERGE_TIMEOUT_SECONDS`. If the PR remains queued until
the timeout, it records `merge_pending`, preserves the branch and issue, and
stops the run by default; `RALPH_MERGE_PENDING_POLICY=continue` allows it to
continue with other independent issues.
If GitHub has already deleted the branch's remote ref after completing the
merge, Ralph considers it deleted and continues with local deletion, the
post-merge hook, and closing the issue.

## Project agnostic

Install a tagged `ralph/` release in any repository with a GitHub remote and it
works (see [Distribution and version](#distribution-and-version)). It assumes
no language, framework, or test runner: agents infer test, lint, and type-check
commands by reading `AGENTS.md`, `CLAUDE.md`, `README`, `CONTRIBUTING.md`, and
the project's manifest (`Makefile`, `package.json`, `pyproject.toml`,
`Cargo.toml`, `go.mod`, `.github/workflows/`…). If those files disagree with the
manifest, the agent instructions take precedence.

## Usage

```bash
./ralph/once.sh                                  # base = repository trunk (main/master)
RALPH_BASE_BRANCH=develop ./ralph/once.sh        # explicit base
RALPH_MAX_ROUNDS=2 ./ralph/once.sh               # fewer rounds, lower cost
RALPH_DRY_RUN=1 ./ralph/once.sh                  # read-only plan
```

The reviewer defaults to the `opus` alias, which Claude Code resolves to the
latest Opus model, with `medium` effort. To make that choice explicit, or to
override it for a run:

```bash
RALPH_CLAUDE_MODEL=opus RALPH_CLAUDE_EFFORT=medium \
  ./ralph/once.sh
```

`RALPH_CLAUDE_EFFORT` accepts `low`, `medium`, `high`, `xhigh`, or `max` and
is passed to Claude Code as `--effort`. Opus 5.5 uses adaptive thinking; the
effort level controls its depth, so Ralph does not send a `thinking` or
`budget_tokens` option. Use `RALPH_SMOKE_TEST=1` to verify model access before
Ralph queries issues.

Codex defaults to the current `gpt-6-luna` model with `max` reasoning. The
current Codex catalog does not expose a generic `luna` alias, so a future Luna
model ID requires updating this default or setting `RALPH_CODEX_MODEL` for the
run.

## Real GitHub integration

The suite that uses real GitHub is not part of `bats tests/` or normal CI. Run
it explicitly with `make integration` or from the manual workflow
`.github/workflows/integration.yml`. The default target is
`nicoamigosa/ralph-sandbox`; for another sandbox, configure the exact slug in
both values before running:

```bash
export REPO_SLUG=nicoamigosa/ralph-sandbox
export RALPH_SANDBOX_SLUGS=nicoamigosa/ralph-sandbox
export GH_TOKEN='token-with-contents-issues-and-pull-requests-write'
export RALPH_REVIEWER_GH_TOKEN='different-read-only-token'
make integration
```

The harness compares `REPO_SLUG` with the allowlist before running `gh auth
setup-git`, cloning, creating issues, or performing any other write. A slug
outside the allowlist exits with code 2. `GH_TOKEN` and
`RALPH_REVIEWER_GH_TOKEN` must be different credentials; they are not written to
`.env` files.

### Prepare `ralph-sandbox`

The sandbox must have the `ready-for-agent` label and a pull request workflow
whose job is named `test`. The minimal test can be:

```yaml
name: Sandbox CI
on: [pull_request, push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: test ! -e .ralph-integration-fail
```

In Settings → Rules → Rulesets, create an active ruleset for `main` that
requires the `test` status check and has no bypass actors. Do not require human
approvals: the identity running the suite must be able to merge when `test` is
green, but must not bypass the ruleset. The workflow must be on `main` before
launching the suite so GitHub runs the check on every PR.

The suite creates one issue per scenario, replaces Codex and Claude with
fixtures under `tests/integration/`, and checks the remote state. In order, it
runs PASS with green CI (merge), PASS with red CI (open PR), rejection (open PR
with a comment), and agent error (no merge). At the end it closes the issues,
closes unmerged PRs, and deletes their branches. The merged PR remains as
immutable GitHub history; cleanup ensures no scenario PRs or branches remain
open. You can limit the run, for example,
`RALPH_INTEGRATION_SCENARIOS=pass-green make integration`.

The base is **never** the branch you are currently on: it is the repository
trunk, detected with `gh repo view` (`main` or `master`, depending on the
repository). Every approved PR is merged there, and the next issue's branch is
created from it.

`RALPH_DRY_RUN=1` prints the selector plan —priority, host, parents, blockers,
human-review exclusion, and existing PR—then ends before checkout, agents,
labels, push, or merge. It also reads the remote lock ref: if another run is
active, it reports it and never claims or modifies that ref. This lets you
inspect a run without modifying the repository or GitHub.

Requirements for a complete run: Bash **5 or newer**, `git`, `gh` (authenticated
with `repo` scope), `jq`, `codex`, `claude`, an `origin` remote, and a **clean
working tree** —the script switches branches and merges. In addition,
`RALPH_TDD_SKILL` must point to a readable `SKILL.md`; Ralph adds it only to
Codex's context. Before querying issues, preflight validates Codex
(`codex login status`), Claude (`claude auth status --json`), and GitHub
(`gh auth status`) sessions, checks `jq`, and verifies the minimum supported
versions: Codex `0.154.0`, Claude `2.1.277`, and gh `2.45.0`. Versions are
recorded in `run.log`, `summary.json`, and `summary.md`.

`RALPH_SMOKE_TEST=1` enables a minimal call to both models after preflight. An
inaccessible model stops the run as a configuration error, before listing or
touching issues; it is disabled by default because it consumes budget. Dry-run
still does not require Codex or Claude login, although it does need `git`, `gh`,
and `jq` to build the plan. On macOS, install Bash with `brew install bash` and
prepend `$(brew --prefix bash)/bin` to `PATH`. `once.sh` uses the native `date`
formats for Darwin and Linux and temporary files under `${TMPDIR:-/tmp}`, with
no additional GNU utilities required. The dry-run plan uses only those
read-only tools.

## How issues are selected

1. Open issues with the `ready-for-agent` label, **in ascending number order**.
   The query uses an explicit high limit (`1000`) so it does not inherit gh's
   default limit of 30 results; that limit affects only the query, not the number
   of issues the selector tries to process.
2. Before creating a branch, it rereads and validates each candidate's body,
   state, and labels. A failed `gh issue view` stops the pass (it is never
   interpreted as a body with no dependencies). An issue with
   `ralph-needs-human` is skipped, as is a PR with that label.
3. It excludes **epics**: any issue referenced by another under `## Parent`.
   To detect them, Ralph also inspects closed children and children without the
   candidate label.
4. It respects dependencies: it skips issues with open blockers under
   `## Blocked by`. Each blocker's state is queried **when it is evaluated**, not
   from the list cached at the start of the pass: GitHub's API is eventually
   consistent and may still return an issue as open immediately after it was
   closed, falsely blocking its dependents. Live queries also unblock them
   within the same pass (which is why the merge to the base happens before
   continuing: dependents inherit the code).

Before evaluating dependencies, Ralph detects the local host with `uname -s`:
`Darwin` is `macos` and `Linux` is `linux`; any other system stops the run. An
issue with `ralph-host:macos` or `ralph-host:linux` is processed only on that
host. With neither label it can run on either host. If it has both, the labels
contradict each other and the issue is explicitly blocked. Dry-run shows
`host=<required> current=<current>` for each issue.

Before invoking each agent, Ralph repeats the state, label, and blocker
validation. If the issue loses `ready-for-agent`, is closed, becomes blocked, or
receives `ralph-needs-human` while the run is in progress, no agent is invoked
and the branch is preserved for the next pass.

## Priority order

The default order is the issue number, which rarely matches priority.
`RALPH_ISSUE_ORDER` sets it without touching issues:

```bash
RALPH_ISSUE_ORDER="127 124 126 128" ./ralph/once.sh
```

Those issues come first and in that order; the rest follow by number. A number
that is not open and labeled is silently ignored: the list **orders** work, it
never **creates** it. It also does not skip dependencies —an issue with open
blockers is still postponed even if it heads the list.

This is what you should use to chain several slices without intervention. The
alternative —inventing `## Blocked by` relationships between unrelated issues—
turns a field that means “this needs that code” into a priority field, and then
no one knows which of the two meanings was intended.

Expected format in the issue body:

```markdown
## Parent
#25

## Blocked by
- #26
- #28
```

Section headings are compared case-insensitively, and a section ends at the next
`## `. Each reference must occupy a complete line (`#N` or `- #N`, with
optional spaces); a trailing `\r` is accepted. Under `## Blocked by`, any
non-empty line outside that format blocks the issue, and Ralph reports the error
explicitly.

## Idempotence

If a run is interrupted (Ctrl-C, usage limit, crash), the next one **reuses** the
existing branch and PR instead of recreating them, and skips anything already
merged. Running `./ralph/once.sh` again is always safe.

At the start of each issue, Ralph runs `git fetch origin`. If the issue branch
exists only remotely, it restores it with tracking and reviews the existing PR
without invoking Codex again. When both copies exist, it requires equality or a
fast-forward; a divergence preserves the branch, labels the PR (or the issue if
there is no open PR) `ralph-needs-human`, and does not launch agents.

Before implementing, it queries open, closed, and merged PRs associated with the
branch or issue. An already merged PR whose issue is still open is reconciled by
applying `RALPH_CLOSE_POLICY`, rather than creating another branch or
implementation.

After preflight, each normal run applies `umask 077`, generates a UTC `RUN_ID`
(`YYYYMMDDTHHMMSSZ-<pid>`), and stores its artifacts in
`$SCRIPT_DIR/runs/$RUN_ID/`. `run.log` receives all output after preflight;
`events.log`, `last-message.txt`, `summary.json`, and separate stdout/stderr
captures for each agent remain there after completion. `runs/` is ignored by the
distributed `.gitignore`, and dry-run does not create that directory. The
summary always ends with an explicit `stop_reason`; `issues_started` counts
unique issues started in the run; an issue failure is not reported as
`no_ready_issues`.

On exit, the trap preserves the original code and finalizes `summary.json` and
`summary.md`. The JSON includes `run_id`, `stop_reason`, `issues_started`,
`merged`, `open_prs`, `needs_human`, `blocked`, `errors`, `elapsed_seconds`, and
`usage` with `codex_tokens` and `claude_estimated_usd`. `versions.codex`,
`versions.claude`, and `versions.gh` preserve the versions observed during
preflight. The four work states are lists with issue/PR numbers and links;
`events.jsonl` preserves one JSON event per line associated with the issue and,
when present, the PR. A usage value the provider does not supply is `null`,
never `0`. `claude_estimated_usd` is only the estimated cost reported by the
provider: Ralph does not calculate subscription marginal cost or present it as
actual billing. The run budget covers only that estimated Claude cost; it is not
a shared budget with Codex.

At the end of a normal run, Ralph prints the path to `summary.md` on stdout. If
`RALPH_REPORT_ISSUE` contains an issue number, it publishes that file as the
only additional comment on the specified issue. If GitHub rejects the
publication, it warns, preserves the file, and keeps the run's original exit
code.

## Host exclusion

Each normal run atomically acquires `refs/ralph/lock` on `origin` with a
creation `git push`. The ref's commit contains the host, PID, start time, and
last heartbeat; while the run is active, Ralph renews it with
`--force-with-lease` and releases it with the same lease in the exit trap. A
second run, even from WSL or macOS, exits before selecting issues, agents,
labels, pushing, or merging.

The heartbeat is considered expired after `RALPH_LOCK_TTL_SECONDS` and can be
claimed with another atomic compare-and-swap. The default is twice
`RALPH_AGENT_TIMEOUT_SECONDS`. A claim prints the previous host and PID; a lock
with invalid metadata stops the run (fail-closed). Dry-run only reads this ref
and never creates, renews, claims, or releases it.

Ralph never creates commits to hide work Codex left uncommitted: it preserves the
tree and stops the run with code 70 so the state can be recovered manually. It
also stops the run on `checkout`, `fetch`, `push`, or `pull --ff-only` failures;
a conflict Codex does not resolve is aborted when possible, the tree is
preserved otherwise, and the PR is left labeled for a human.

## Processes

Each `codex exec` and `claude` invocation runs in its own session/process group.
When `setsid` exists it creates the session; on macOS without `setsid`, Bash 5
uses job control (`set -m`) to obtain a separate group. stdout and stderr are
streamed through separate captures, but the agent group is isolated from the
`once.sh` group: a signal sent to the agent does not terminate the orchestrator.

When an agent ends, Ralph terminates its complete group, including orphaned
processes such as servers, watchers, or hung tests. It checks that the group is
not its own before doing so, so it never kills itself. An agent that ends from a
signal (`rc >= 128`) is an infrastructure failure: it produces neither a
verdict nor success.

`once.sh` handles `TERM`, `INT`, and `HUP`. It records the signal, phase, and
issue, preserves the tree and branch as they were, and exits with `128 +
signal`; it does not perform a checkout or destructive reset. It also stores the
reason and signal data in the run's `summary.json`.

Each Codex or Claude invocation, the `RALPH_POST_MERGE_CHECK` hook, and CI/merge
confirmation waits pass through a GNU `timeout --kill-after=30s` limit. The
effective limit never exceeds the run's remaining time. If a command times out,
the state is `timeout` —not a provider limit—, the branch is preserved when it
still exists, and the run stops; a timed-out post-merge hook also prevents
chaining another issue.

## Agent JSON adapters

Codex runs with `codex exec --json -o "$LAST_MSG"` and Claude with
`claude --print --output-format json`. Each execution preserves its
`<agent>-<n>.stdout.jsonl|json`, `<agent>-<n>.stderr.log`, and
`<agent>-<n>.result.json` files under `RUN_DIR`; stdout is never mixed with
stderr.

The internal contract for both adapters is:

```json
{"status":"ok|rate_limited|auth_error|config_error|timeout|failed|unknown","retry_at":null,"limit_scope":"session|weekly|unknown","retryable":false,"exit_code":0,"final_message":null,"error":null}
```

`ok` requires exit code zero and a valid terminal output: `turn.completed` for
Codex and a `type=result` object with a `result` field for Claude. Invalid,
truncated, or terminal-result-free JSON is `failed`; the gate does not merge
that issue.

Supported outputs and their versioned fixtures are Codex CLI **0.154.x**
(`tests/fixtures/codex-0.154.0-*.jsonl`) and Claude Code **2.1.x**
(`tests/fixtures/claude-2.1.277-success.json`). Updating either format requires
updating the fixture and adapter first.

The fixtures were captured from real executions on this host. Codex CLI reported
version 0.154.0 with `codex --version`, and Claude Code reported version 2.1.277
with `claude --version`.

The exact Codex capture command was:

    codex exec --json -o "$capture_dir/last-message.txt" --skip-git-repo-check "Respond with exactly: real codex fixture capture. Do not modify files, run commands, or use tools."

The exact Claude capture command was:

    claude --model opus --effort medium --dangerously-skip-permissions --print --output-format json "Respond with exactly: <verdict>PASS</verdict>. Do not modify files, run commands, or use tools."

In both executions, stdout and stderr were redirected to separate files; the
fixtures contain raw stdout. `codex-0.154.0-truncated.jsonl` is the same real
Codex stdout truncated halfway through the `turn.completed` event.

## Reviewer failures vs. rejections

Claude does not publish comments: if execution fails before returning its body,
the remote state remains at `phase=revisión`, with the same round and SHA, so the
next attempt can resume that review without consuming budget. A valid response
is published once as the exact body; the round advances only after Codex
completes the fix.

A response without a well-formed verdict, or a `CHANGES_REQUESTED` with no
numbered finding, is treated as reviewer infrastructure failure: it is retried
up to `RALPH_MAX_INFRA_RETRIES` without consuming a round or publishing
anything. After retries are exhausted it remains `CHANGES_REQUESTED`
(fail-closed). The reviewer runs with
`--disallowedTools Monitor,ScheduleWakeup,CronCreate,Agent` because each
background-tool wake-up is a new turn and `claude --print` returns only the
last one, losing the review.

## Usage limits

The adapters classify a limit only from an error event or structured provider
metadata. Responses, diffs, final messages, and tool output are not usage
signals. A `retry_at` is accepted only as an epoch or an RFC3339 timestamp with
a timezone inside that signal; if absent, it remains `null` and the retry is
immediate, without inventing a session or week.

Each issue allows at most `RALPH_MAX_LIMIT_RETRIES` retries. A reliable reset is
awaited only until that instant and is bounded by `RALPH_DEADLINE_EPOCH` when it
exists. `auth_error` and `config_error` stop the run and write a checkpoint;
`unknown` records the error and does not wait.

## Files

| File | Role |
|---|---|
| `once.sh` | Orchestrator: issue selection, branches, merges, usage limits |
| `prompt_implement.md` | Codex: implement the issue and open the PR |
| `prompt_review.md` | Claude: review the PR and issue the verdict |
| `prompt_revise.md` | Codex: address review comments |
| `prompt_conflicts.md` | Codex: resolve conflicts when updating the branch with the base |
| `update.sh` | Download and verify a release before updating the installation |
| `MANIFEST` | Paths of files that make up the distribution |
| `VERSION` | Installed release; `update.sh --check` compares it with the latest stable release |
| `last_run.md` | Checkpoint, generated when stopping for a global limit/error (not versioned) |

## Configuration levels

`ralph/` is **shared and identical** in every repository that uses it: it is
never edited in the project. Variable configuration lives outside it:

| Level | Location | Contents |
|---|---|---|
| Shared | `ralph/` | Script, prompts, contracts, tests, updater, `VERSION` |
| Project | `.ralph/config.env` | Base, labels, required checks, close policy, post-merge hook |
| Project | `.ralph/prompt_*.local.md` | Concrete implementation/review constraints appended to the shared prompt |
| Host | `~/.config/ralph/host.env` | Linux/macOS capability, paths (Homebrew `PATH`, `gtimeout`), local limits |
| Credentials | Login / keychain / protected environment | `gh`, `codex`, and `claude` authentication; never in versioned config |

At startup, Ralph resolves the root with `git rev-parse --show-toplevel`, moves
its working directory there, and loads `.ralph/config.env`. It then loads
`${RALPH_HOST_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ralph/host.env}` if it
exists. Precedence is explicit environment > host > project > defaults; to
guarantee it, `RALPH_*` variables already in the environment are captured before
`source` and restored after loading. `.env` files are trusted shell code (they
are sourced), not parsed data: they must contain only code the operator has
audited.

Shared prompts are read from `ralph/` before switching to an issue branch.
`load_prompt <name>` adds `.ralph/<name>.local.md`, when it exists, under
`# Project-specific requirements`; project-specific constraints live there
without modifying distributed prompts.

## Configuration

Except for the required `RALPH_TDD_SKILL`, everything is optional; values can
come from the environment, `.ralph/config.env`, or `host.env`:

| Variable | Default |
|---|---|
| `RALPH_LABEL` | `ready-for-agent` |
| `RALPH_BASE_BRANCH` | repository trunk (`main`/`master`) |
| `RALPH_BRANCH_PREFIX` | `ralph/issue-` |
| `RALPH_MAX_ROUNDS` | `3` |
| `RALPH_MAX_ISSUES` | `5` |
| `RALPH_MAX_RUN_SECONDS` | `14400` |
| `RALPH_CODEX_MODEL` | `gpt-6-luna` |
| `RALPH_CODEX_EFFORT` | `max` |
| `RALPH_CODEX_SANDBOX` | `workspace-write` (in this mode Codex mounts `.git` read-only; ralph enables it as `writable_root` and runs a preflight probe; `danger-full-access` is not recommended) |
| `RALPH_CLAUDE_MODEL` | `opus` (latest Opus alias) |
| `RALPH_CLAUDE_EFFORT` | `medium` (`low`, `medium`, `high`, `xhigh`, or `max`) |
| `RALPH_TDD_SKILL` | required: path to a `SKILL.md` readable by Codex |
| `RALPH_SMOKE_TEST` | `0` (with `1`, test both models before querying issues) |
| `RALPH_REVIEWER_GH_TOKEN` | required for the reviewer: a GitHub fine-grained token limited to this repository with read permissions |
| `RALPH_REQUIRE_REVIEWER_TOKEN` | `1` (only `0` together with `RALPH_REQUIRE_PROTECTION=0` in the sandbox) |
| `RALPH_MERGE_METHOD` | `--squash` |
| `RALPH_MERGE_TIMEOUT_SECONDS` | `600` |
| `RALPH_MERGE_PENDING_POLICY` | `stop` (`continue` is the explicit alternative) |
| `RALPH_NEEDS_HUMAN_LABEL` | `ralph-needs-human` |
| `RALPH_MAX_INFRA_RETRIES` | `3` |
| `RALPH_MAX_LIMIT_RETRIES` | `3` |
| `RALPH_DEADLINE_EPOCH` | empty (no global deadline) |
| `RALPH_CI_POLICY` | `required` |
| `RALPH_CI_TIMEOUT_SECONDS` | `1800` |
| `RALPH_REQUIRED_CHECKS_JSON` | empty (uses all reported checks) |
| `RALPH_AGENT_TIMEOUT_SECONDS` | `1800` (lock TTL base) |
| `RALPH_LOCK_REF` | `refs/ralph/lock` |
| `RALPH_LOCK_TTL_SECONDS` | `2 × RALPH_AGENT_TIMEOUT_SECONDS` |
| `RALPH_LOCK_HEARTBEAT_SECONDS` | half the TTL (minimum `1`) |
| `RALPH_LOCK_HOST` | host name (`uname -n`) |
| `RALPH_CLOSE_POLICY` | `verified` (accepted values: `verified` \| `never`) |
| `RALPH_REQUIRE_PROTECTION` | `1` |
| `RALPH_MERGE_IDENTITY` | empty (`gh api user` login) |
| `RALPH_REVIEW_IDENTITY` | empty (no separate reviewer identity) |
| `RALPH_ISSUE_ORDER` | empty (order by number) |
| `RALPH_REPORT_ISSUE` | empty (does not publish the summary; if set, comments `summary.md` on that issue) |
| `RALPH_POST_MERGE_CHECK` | empty (no production verification) |
| `RUN_DIR` | `$SCRIPT_DIR/runs/<RUN_ID>` (captures, events, `summary.json`/`.md`, and agent contracts; explicit override preserved for tests) |
| `RALPH_CHECKPOINT_FILE` | `$SCRIPT_DIR/last_run.md` |
| `RALPH_HOST_CONFIG` | `${XDG_CONFIG_HOME:-$HOME/.config}/ralph/host.env` |

With `RALPH_CODEX_SANDBOX=workspace-write`, ralph replaces any
`writable_roots` configured by the user in `~/.codex/config.toml` with the
current repository's absolute `.git` root. Before the first issue it runs a
model-free probe that writes and deletes a file there; if `codex sandbox` is not
available on the platform, it warns and continues. `danger-full-access` avoids
that restriction, but is not recommended because it exposes the entire
filesystem.

The reviewer receives `RALPH_REVIEWER_GH_TOKEN` only as `GH_TOKEN` in its child
process. Preflight requires it to differ from the orchestrator's `GH_TOKEN`.
Create a fine-grained token with access only to the target repository and read
permissions for `Metadata` (required by GitHub), `Contents`, `Issues`, and `Pull
requests`; store it in the host's protected environment, never in
`.ralph/config.env` or a versioned file. `RALPH_REQUIRE_REVIEWER_TOKEN=0` is
accepted only together with `RALPH_REQUIRE_PROTECTION=0`, reserved for the
sandbox; in that case the reviewer does not inherit `GH_TOKEN`.

Codex, Claude, and `RALPH_POST_MERGE_CHECK` processes inherit the host's normal
environment —including `PATH`, credentials, and `TMPDIR`— except for `RALPH_*`
variables: `once.sh` configuration is not exported to agents or the hook.
`RALPH_POST_MERGE_CHECK` receives the confirmed merge SHA as its first and only
positional argument (`$1`); any additional data must come from its own
non-`RALPH_*` environment or external files.

## Distribution and version

`ralph/` is distributed as a **tagged release** of the repository
[`nicoamigosa/ralph`](https://github.com/nicoamigosa/ralph); `VERSION` says
which one is installed. No subtree, submodule, or copy from `main` is used: none
pins or verifies the version being run.

- Install/update: `ralph/update.sh <VERSION>` downloads that release, verifies
  the tarball against `SHA256SUMS`, rejects local modifications to shared files,
  and applies only the paths in `MANIFEST`; it preserves `runs/`, checkpoints,
  and all of `.ralph/`. While `once.sh` runs, the remote lock
  `refs/ralph/lock` prevents updates. The updater never creates commits: the
  diff remains for a normal PR.
- Check for updates: `ralph/update.sh --check` queries GitHub releases, ignores
  drafts and pre-releases, and compares `VERSION` with the latest stable
  release. It emits exactly `actual` (code 0), `actualización disponible: vX.Y.Z`
  (code 10), or `consulta fallida` (code 20); a failed query **never** means the
  installation is current.

Each release publishes two assets with fixed names: `ralph-v<VERSION>.tar.gz` and
`SHA256SUMS`. The latter contains the SHA-256 of the former. To detect local
edits, `update.sh` also downloads and verifies the tarball for the currently
installed version before comparing its `MANIFEST` files. Therefore, assets from
previous releases must be retained.

### Publish a release

After `bash -n once.sh update.sh`, `shellcheck once.sh update.sh`, and
`bats tests/` pass, version `VERSION`, commit, and create the `v<VERSION>` tag.
Build the tarball from `MANIFEST` so files outside the distribution are not
included:

```bash
version="$(cat VERSION)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/ralph-release.XXXXXX")"
root="$stage/ralph-v$version"
mkdir -p "$root"
while IFS= read -r path || [ -n "$path" ]; do
  case "$path" in ''|'#'*) continue ;; esac
  mkdir -p "$root/$(dirname "$path")"
  cp -p "$path" "$root/$path"
done < MANIFEST
tar -czf "$stage/ralph-v$version.tar.gz" -C "$stage" "ralph-v$version"
(cd "$stage" && if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "ralph-v$version.tar.gz" > SHA256SUMS
else
  sha256sum "ralph-v$version.tar.gz" > SHA256SUMS
fi)
gh release create "v$version" "$stage/ralph-v$version.tar.gz" \
  "$stage/SHA256SUMS" --title "ralph $version"
```

Publish only after the tag exists on the remote; the tarball and its checksum
must correspond exactly to that tag.

## Design notes

- **Claude returns, Ralph publishes and merges.** Claude does not use `gh pr comment`:
  its final result contains the complete review body, and Ralph publishes it
  exactly with `gh pr comment`. It then leaves another remote comment marked
  `<!-- ralph-state -->` with the returned ID, PR, phase, round, reviewed SHA,
  result, and merge state. Resumption reconstructs the latest marked record
  from GitHub, so a later unrelated comment does not replace the review Codex
  receives.
- **The reviewer credential is read-only.** `RALPH_REVIEWER_GH_TOKEN` replaces
  the orchestrator's `GH_TOKEN` only inside Claude's process, so the reviewer
  can inspect the PR without publishing comments or mutating GitHub. The token
  must be limited to the repository and read permissions;
  `RALPH_REQUIRE_REVIEWER_TOKEN=0` is an exception only for the sandbox.
- **Known v1 limitation:** there is no container isolation. Claude still runs
  with `--dangerously-skip-permissions` and can access the workspace and local
  capabilities provided by the host; v1 isolates only the GitHub credential
  used by the reviewer.
- The remote log uses immutable events: before each agent it records the current
  phase and round, and advances the round only after the fix is complete. A
  limit, timeout, or restart resumes the same phase, round, and SHA. The merge
  is published as `merge_pending` and `merged`, and only after a well-formed
  `PASS`. This mode **is not equivalent to a GitHub required review**: the
  server does not guarantee PASS, only the script. To guarantee it, a review/
  merge identity separate from the implementer and a no-bypass ruleset on the
  base are required; until then, the ruleset can require only status checks.
- **The script closes the issue, not the agent.** `Closes #N` autocloses only
  when the PR targets the default branch; the base here is configurable.
- **Closing depends on policy.** With `RALPH_CLOSE_POLICY=verified`, the script
  closes only after PASS, a confirmed merge, and `Closes #N` in the PR body. A
  `Part of #N`, or any missing declaration, leaves the issue open and comments
  on the merge. With `RALPH_CLOSE_POLICY=never`, it never uses `gh issue close`,
  even if the PR contains `Closes #N`. The script closes the issue, not the
  agent; GitHub's native `Closes #N` autoclose applies only when the PR targets
  the default branch, while `verified` makes closure explicit after
  verification.
- **Codex runs with `network_access=true`** inside the `workspace-write`
  sandbox, which is the minimum it needs for `git push` and `gh pr create`.
- **The branch is updated with the base before each review**, using `git merge`
  and never `rebase`: the reviewer sees exactly what will be merged, and Codex
  resolves conflicts without consuming a round.
- **Green CI is a merge condition in addition to PASS.** With red CI, the
  script leaves the failed run as the sole review item and Codex fixes it.
- **A post-merge hook can stop the run.** `RALPH_POST_MERGE_CHECK` receives the
  merged SHA; if it returns ≠0, the issue is labeled and ralph does not chain
  another deployment onto production that has not been verified.

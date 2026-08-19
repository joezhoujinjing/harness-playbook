# Rules for Writing a CLI an AI Agent Can Use

*Follow these when generating a CLI tool. Assume the agent is the primary caller and humans
invoke it mainly to test. Each rule is checkable against your own output.*

**Before rule 1:** where a shell exists, prefer a CLI over an MCP server — MCP tool definitions
occupy context permanently, a CLI costs nothing until called. Reach for MCP only when the host has
no shell, you need per-user permissions and audit trails, or the target system has no CLI.

1. **Default output to under 200 tokens per command.** Show 3–4 fields per item, not 10. Provide `--full` for more.

2. **Default to line-oriented output — TSV with a header row, not JSON.** Agents pipe into `head`, `grep`, and `tail` far more than `jq`, and `| head` turns pretty JSON into a broken fragment. Offer `--jsonl` when a program is the consumer. Do not implement TTY detection: stdout is always non-TTY here, and a separate human rendering path means humans never test what the agent receives.

3. **Use noun-then-verb subcommands.** `tool user create`, never `tool create-user`. Group by resource so `tool <noun> --help` lists all verbs. Add a `describe` subcommand emitting the command tree with flags, defaults, and exit codes — `--help` is an API, not prose.

4. **Use distinct non-zero exit codes per error category.** At minimum: 2=validation, 4=not-found, 5=conflict, 7=auth, 8=rate-limit, 9=transient. Never return 1 for everything.

5. **Return errors as line-oriented `key: value` on stderr, including a directly executable `retry:` command.** Data on stdout, errors on stderr, never mixed. The `retry` line beats a structured error object the agent would have to parse and reassemble.

6. **Make every mutation idempotent or provide `--if-not-exists` and `--dry-run`.** Running a command twice must not fail the second time. `--dry-run` returns a structured plan (`will_create=3 will_modify=12`), not a paragraph.

7. **Replace every interactive prompt with a flag.** If a required value is missing, exit with a clear error naming the missing flag — never hang. Non-interactive should be the only mode, not something a `--no-interactive` flag guards.

8. **Print explicit output for empty, no-op, and success cases.** Empty list → `count=0`. No-op → `already exists, no changes`. Never rely on silence: an agent cannot distinguish "succeeded quietly" from "crashed".

9. **Write data to stdout only, errors to stderr only, and never write progress, spinners, or colors.** The output must be safe to pipe. Both stdout and stderr are captured into context, so moving progress to stderr saves nothing — emit one timing line at the end and put real progress behind `--progress`.

10. **Ship a `SKILL.md` next to the binary.** Include: install command, auth setup, the 5 most-used commands with real output samples, and the 3 most common error recoveries. Keep it under 100 lines. Its `description` is always resident and is the only trigger signal, so state both what the tool does and when to use it.

11. **Send large results to a file and print a summary plus the path.** A large result set must never enter context; the agent greps the artifact when it needs detail.

12. **Ship `verify` and `status` subcommands.** Agents lose context between turns and need to ask rather than guess: does the config compile, where did the last run get to, are the artifacts stale.

13. **Version the output schema.** Carry `schema=tool.v1` in the header row and bump it on breaking changes — agents parse your output, and a silent rename is a silent crash.

14. **Set the regression bar at "the agent got it right first try", not "the command worked".** An agent-first CLI has no human complaint channel. Replay real invocation traces and track retries, `--help` re-reads, and whether the agent bypassed the CLI to write its own script — the last is the strongest signal the tool is bad.

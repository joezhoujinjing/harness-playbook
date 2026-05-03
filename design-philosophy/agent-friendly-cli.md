# 10 Rules for Writing a CLI an AI Agent Can Use

*Follow these when generating a CLI tool. Each rule is checkable against your own output.*

1. **Default output to under 200 tokens per command.** Show 3–4 fields per item, not 10. Provide `--full` for more.

2. **Support `--json`, `--quiet`, and `--no-interactive` on every command.** Auto-enable all three when stdout is not a TTY.

3. **Use noun-then-verb subcommands.** `tool user create`, never `tool create-user`. Group by resource so `tool <noun> --help` lists all verbs.

4. **Use distinct non-zero exit codes per error category.** At minimum: 2=validation, 4=not-found, 5=conflict, 7=auth, 8=rate-limit, 9=transient. Never return 1 for everything.

5. **In `--json` mode, return errors as `{"error": {"code", "message", "retryable", "hint"}}` on stderr.** Data on stdout, errors on stderr, never mixed.

6. **Make every mutation idempotent or provide `--if-not-exists` and `--dry-run`.** Running a command twice must not fail the second time.

7. **Replace every interactive prompt with a flag.** If `--no-interactive` is set and a required value is missing, exit with a clear error naming the missing flag — never hang.

8. **Print explicit output for empty, no-op, and success cases.** Empty list → `{"items": [], "count": 0}`. No-op → `"already exists, no changes"`. Never rely on silence.

9. **Write data to stdout only, errors to stderr only, and never write progress, spinners, or colors when stdout is non-TTY.** The output must be safe to pipe.

10. **Ship a `SKILL.md` next to the binary.** Include: install command, auth setup, the 5 most-used commands with `--json` examples, and the 3 most common error recoveries. Keep it under 100 lines.

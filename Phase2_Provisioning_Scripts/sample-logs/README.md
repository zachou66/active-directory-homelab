# Sample Logs

Drop a trimmed `Start-Transcript` output here from a real run of `Onboarding.ps1`.

To generate one, and to also capture the **idempotency proof** (the strongest artifact for
Phase 2), run the script twice:

1. First run — creates the users. Transcript shows `CREATED - <user>` lines.
2. Second run, same CSV — transcript shows `SKIPPED - <user> already exists` for every row.

Commit one trimmed transcript from each run (or one file showing both), with any real
paths/hostnames left as-is since they're internal lab values.

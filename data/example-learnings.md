# Example operational lessons

These examples show concise lessons that are specific enough to guide future work.

- Tool quirk: `sq-gh` requires the full repository URL for cross-host lookups; pass the URL instead of relying on the current remote.
- Tool quirk: `sq-test-run.sh` accepts one test path for focused verification; use it before selecting a broader test family.
- Commander preference: When a decision changes the implementation approach, record the decision before continuing so later workers do not restore the rejected design.
- Commander preference: Keep commander-facing updates focused on outcome, consequence, and the next decision rather than internal lifecycle details.
- Architectural decision: Domain-local operational knowledge belongs in `data/learnings.md`; shared contributor knowledge belongs in tracked documentation.
- Architectural decision: A status event is a notification, not current-state truth; reconcile current state before acting on an old event.
- Failure pattern: Repeated direct retries of a failed steer do not resolve an unresponsive worker; inspect the recorded endpoint and preserve the isolated copy before recovery.
- Failure pattern: A missing external credential is a blocker, not a reason to silently switch tools or lower the requested rigor.

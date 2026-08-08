# LEARNINGS.md — ratchet mistake ledger (read before working)

## Selftest gotchas

- **Backgrounded-async test needs a yield, not a tight spin.** A test that fires
  `cmd &` then polls for its side-effect MUST `sleep` between polls. A bare
  `while [ ! -f ... ]; do i=$((i+1)); done` loop can exhaust its iteration cap
  (50x) before the backgrounded `sh -c` even forks — flaky RED that passes in
  isolation. Always `sleep 0.0x` inside the poll loop. (hit T3.1: notify_human
  NOTIFY_CMD hook marker race.)
- **`refresh_rank_snapshot` is NOT hermetic — it hits the live `pi` binary and
  the network (models.dev).** Tests that call it must stub `pi_model_registry`
  and `model_cost_registry` to serve fixture caches, or it `die`s and the whole
  selftest exits silently (its `>/dev/null 2>&1` swallows the error). The live
  refresh is intentional for the `ratchet models rank refresh` CLI command; the
  test just has to stub it.
- **A `die` mid-selftest exits the process with no visible output** when the
  failing call is wrapped in `>/dev/null 2>&1`. Symptom: selftest stops at suite
  N with EXIT=1, empty stderr, no `fail` line, no summary. Hunt for the last
  `ok` printed, then read the test block immediately after it.

## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T03:33:50Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T04:10:08Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T04:42:34Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T05:11:10Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T05:43:34Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T06:12:09Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T06:44:32Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T07:01:31Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T07:34:03Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T08:06:27Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T08:23:46Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T09:11:39Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T09:30:25Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T10:04:02Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T10:20:14Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T11:10:20Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T11:43:16Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T12:07:07Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T12:39:29Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T13:08:05Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T13:27:19Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T13:49:13Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T14:06:12Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T14:25:16Z
## auto-captured
  ok   rank snapshot reused (stable despite registry change)  # 2026-08-08T14:42:36Z

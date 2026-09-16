# Response to the adversarial review of the three build fixes

VERDICT received: BLOCK. Every blocking claim was independently verified
before acting; none was disputed.

## Acted on

| # | Finding | Action |
|---|---|---|
| 1 | Artifacts built from a hand-patched tree; `ef1235b` never executed | Clean rebuild from a **fresh clone** of HEAD, both flavours, `KMODS=1` |
| 5 | `ath.mk` not in `SCAN_DEPS` -> stale packageinfo, `ALL_VARIANTS` may differ clean vs incremental | Integration sets `SCAN_DEPS`. **Correction:** the expression recorded here first was `$(wildcard $(CURDIR)/*.mk)`, which review 3 proved captures `rules.mk` and never `ath.mk` — it did nothing. Fixed in `362a968` to the relative form `*.mk`. |
| 6 | `2>/dev/null \|\| true` made the step invisible AND unable to fail | Both removed; redundant `squeezelite-custom` arg dropped |
| 7 | "no WAN benchmark" false; validation doc self-contradictory | `:384` now scopes it to "at line rate" and says why; release note reworded |
| 8 | "201 ath11k_nss symbols" unreproducible (actual: 48) | No document quotes it; commit message left as-is (immutable) |
| 10c | Stray untracked `~/` dir | Absent from the fresh clone |

## Accepted, not acted on

- **F3** — the smallbuffers pin hard-codes a board assumption inside the donor
  path. True. This port targets one board and the integration already assumes
  it throughout (`+kmod-ath11k-smallbuffers` in DEPENDS predates this change).
  Noted rather than generalised; a second board would need the pin made
  conditional.
- **F3b** — the *plain* build carries 5 silently-resolved Kconfig cycles, two
  self-referential on the ath11k bus packages. Real, pre-existing, and not
  caused by these fixes. Worth its own issue; fixing it inside a release
  rebuild would be scope creep.
- **F9** — the static checks prove compilation, not function. Agreed, and it
  was already the premise of `V19B-TEST-PLAN.md`. Hardware testing follows the
  clean rebuild.

## Not accepted

Nothing. No finding was disputed.

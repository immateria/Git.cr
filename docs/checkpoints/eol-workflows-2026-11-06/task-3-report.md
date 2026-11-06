# Task 3 — replay EOL integration

Status: implementation and stream validation complete; parent task review and sequential integration pending.

- Checkout: `/workspace/work/git-eol-workflows/replay`, branch `feature/eol-replay`.
- Final task commit: `d9e2b57459c379200952f6808aea321773ab3179` (`Support configured EOL conversion in commit replay and rebase`).
- Dependency/base: foundation final `8d6309702ea47693f837d4be44fc090f43d49f78` (includes `e2195ca509cfedc966b9161fcfd41427cf017f71`). Integrate only `d9e2b57` after foundation. Earlier replay WIP tips were consolidated; stash was instructed to rebase its own range with `--onto d9e2b57 e8df1a9`.
- Final checkout is clean. No subagents or pushes. No foundation/shared-file changes.

## Result

Cherry-pick/revert and rebase initiation, continued replay, skip and abort accept and propagate a resolved conversion config. Clean preflight uses worktree attributes with index fallback and retains raw observed file identities. Canonical index edits and merge stages stay unchanged; final relocated writes are materialized using planned result attributes, including conflicted attribute marker data, explicit attribute deletions and nested rules. Worktree expansion is bounded before operation metadata/publication.

The stash preparation seam is implemented exactly as frozen: optional `prepare_worktree : Proc(Array(Index::Entry), Merge::FilePlan, Int64)? = nil` on private `sequencer_start`; invoked once after canonical planning and relocation, before tracked materialization and metadata. Its remaining budget must be within `0..max_total_bytes`. Supplemental preparation cancellation, invalid/zero budgets and mutation of the index are covered. Config and third-parent attribute interpretation remain owned by the stash caller; tracked conversion uses only the tracked final plan.

Rebase onto movement selects changed paths using canonical old/target states, preserving unchanged working bytes during attribute-only updates. Publication guards use raw observations. Sequencer restoration uses immutable original-tree attributes; outer rebase abort uses immutable predecessor/target-tree attributes and exact materialized raw identities.

New replay-owned restoration receipts store bounded, versioned, operation-bound expected raw state maps before restoration writes. `CRYSTAL_SEQUENCER_RESTORE` records original restoration identities; `rebase-merge/worktree-restore` records predecessor and original target identities. Complete serialized receipt bytes are bounded by `max_index_bytes`; each state map is bounded by `max_entries`. A required-marker companion rejects a missing receipt. Retry verifies byte-exact expected serialization and existing receipt without replacing it; changing retry config or info attributes cannot broaden ownership. Recovery never cleans observed data to establish ownership. A retry with conversion settings that select different raw identities fails until the original settings are restored. Existing operation receipts retain foundation's canonical write-ID validation and actual materialized-data digests.

Index checksums are captured before current-index reads and user callbacks in replay, sequencer abort and rebase movement. A preparation callback's index mutation is preserved and rejects the stale plan before metadata.

## Evidence

Pinned oracle asserted with the absolute binary: `/workspace/toolchains/git-2.47.3/bin/git --version` → `git version 2.47.3`. Runtime source continues to use native operations; Git subprocesses appear only in spec fixtures.

Toolchains:

- Crystal 1.22.2 `[1447d239f]`, LLVM 22.1.3, Linux x86_64.
- Crystal 1.13.0 `[6831e441f]`, LLVM 18.1.6, Linux x86_64.

Semantic red against archived pristine `1ff3598` source: new base replay spec compiled and ran **10 examples, 8 errors** because existing sequencer clean checks rejected canonical-clean CRLF working files. Log: `/workspace/work/git-eol-workflows/recon-replay/red-replay.log`. The archived source/spec fixture is `/workspace/work/git-eol-workflows/recon-replay/red`.

Both final compiler lanes passed **327 examples, 0 failures, 0 errors** using:

```sh
source /workspace/toolchains/env.sh
CRYSTAL_CACHE_DIR=/workspace/work/git-eol-workflows/cache-replay crystal spec \
  spec/eol*_spec.cr spec/sequencer_spec.cr spec/rebase_spec.cr \
  spec/rebase_originally_empty_spec.cr spec/rebase_abort_retry_spec.cr \
  spec/merge_partial_recovery_spec.cr spec/descriptor_mixed_recovery_spec.cr \
  spec/external_recovery_writer_spec.cr spec/merge_recovery_metadata_spec.cr --error-trace
```

For the older lane, the exact compiler was `/workspace/toolchains/crystal-1.13.0/bin/crystal`, with `CRYSTAL_CACHE_DIR=/workspace/work/git-eol-workflows/cache-replay-1.13`. Logs: `/workspace/work/git-eol-workflows/recon-replay/final-1.22.log` and `final-1.13.log`.

After that matrix, eight additional distinct partial-publication regressions were added without further source changes. Both lanes passed **18 examples, 0 failures, 0 errors** (eight new examples plus ten imported base replay examples):

```sh
CRYSTAL_CACHE_DIR=/workspace/work/git-eol-workflows/cache-replay-partial crystal spec spec/eol_replay_partial_spec.cr --error-trace
CRYSTAL_CACHE_DIR=/workspace/work/git-eol-workflows/cache-replay-1.13 /workspace/toolchains/crystal-1.13.0/bin/crystal spec spec/eol_replay_partial_spec.cr --error-trace
```

Logs: `/workspace/work/git-eol-workflows/recon-replay/partial-1.22.log` and `partial-1.13.log`. The combined verified scope is 335 distinct examples; final integration/full-suite execution remains parent-owned.

`crystal tool format --check` passed for all owned replay sources and `spec/eol_replay*_spec.cr` under both compilers. `git diff --check` passed. Crystal 1.22 emits existing `IO::Memory.new(... writeable:)` deprecation warnings in untouched pack reader code; 1.13 emits none in this scope.

## Covered behavior

Every new behavior matrix runs with SHA-1 and SHA-256. Tests cover canonical IDs and CRLF working bytes for cherry-pick/revert; conflict markers and real index stages; resolved continue, abort and skip; rebase onto movement, later items and explicit-config continue/skip; original-tree restoration; interrupted outer abort before/after ref publication; immutable receipt retry, changed info attributes, missing receipts and unindexed EOL-only replacements; exact partially published relocation ownership for cherry-pick/revert; interrupted sequencer abort with changed conversion context; incoming/deleted/conflicted/nested planned attributes compared to pinned Git; binary, `-text`, symlink and unchanged canonical byte preservation; expanded output budgets before metadata; cancellation; and raw EOL-only publication races. Existing focused suites cover legacy receipts, descriptor safety, mixed publication and external writers.

Stash's consumer independently reported 154 focused examples passing on both compilers atop the provisional replay dependency; it is rebasing to the final replay tip before its final report. Its consumer validation remains owned by that stream.

## Fix round 1 — findings 1–3

All three findings from `reviews/task-3-review.md` were read verbatim and fixed in additive commit **`87fe5926e55bb70b44e1dd41389b6d8f0cbf653c`**, directly atop reviewed `d9e2b57459c379200952f6808aea321773ab3179`. The reviewed commit was not rewritten. The scoped re-review range is `d9e2b57..87fe592`. Checkout is clean.

1. Restoration now atomically persists `restoring raw-v1` in the **existing durable core operation record**: `CRYSTAL_SEQUENCER_ORIG` or `rebase-merge/state`. This happens after the complete raw receipt has been flushed/synced and before any restoration worktree/index/reference publication. State readers require a correctly versioned restoration receipt whenever this core binding is present; deleting both the receipt and its `.required` companion therefore fails before retry-time conversion can select new ownership. Not-yet-started records and identifiable legacy layouts remain readable; legacy sequencer restoration preserves its legacy primary receipt classification when adding the binding. Public state/result record fields are unchanged.
2. Rebase movement is split into preparation and publication. Initial onto planning, raw observations, canonical index image and **expanded working output** are prepared and checked while no rebase operation metadata exists. Only then are initial rebase state and ORIG_HEAD written; publication reuses the prepared plan and existing index/HEAD/worktree guards. Expanded-budget rejection preserves a preexisting ORIG_HEAD and no callback observes operation metadata.
3. Receipt entry policy follows the clarified ruling: the distinct predecessor/target **path union is at most `max_entries`**, while the combined record count permits two identities per logical path and is bounded by `2 * max_entries` using Int64 arithmetic. The complete receipt byte cap remains unchanged. Disjoint individually fitting maps reject; two variants of one path remain valid at `max_entries: 1`; an Int32::MAX bound does not overflow.

Fail-first evidence: `spec/eol_replay_review_spec.cr` adds ten distinct SHA-1/SHA-256 cases covering outer rebase abort, cherry-pick abort, revert abort, onto expansion/ORIG_HEAD visibility and receipt union/record limits. On reviewed `d9e2b57`, both compiler lanes ran **20 examples, 10 failures, 0 errors** (ten imported base examples plus ten boundary regressions). The loss cases demonstrably completed without the expected refusal; onto callbacks saw metadata; disjoint maps were accepted. Logs: `/workspace/work/git-eol-workflows/recon-replay/review-red-1.22.log` and `review-red-1.13.log`. The new review file then passed 20 examples on 1.22 before broader validation.

Final validation after all fixes: **345 examples, 0 failures, 0 errors under both Crystal 1.13.0 and 1.22.2**, covering the same complete focused scope above with all replay spec files, including the new boundary regressions. Both compiler format checks and `git diff --check` passed. Exact final commands and logs:

```sh
# Crystal 1.13.0; serialized, test-only wrapper disables automatic maintenance.
source /workspace/toolchains/env.sh
GC_MARKERS=1 CRYSTAL_WORKERS=1 \
GIT_ORACLE_BINARY=/workspace/work/git-eol-workflows/recon-replay/git-no-auto-maintenance \
CRYSTAL_CACHE_DIR=/workspace/work/git-eol-workflows/cache-replay-1.13 \
/workspace/toolchains/crystal-1.13.0/bin/crystal spec \
  spec/eol*_spec.cr spec/sequencer_spec.cr spec/rebase_spec.cr \
  spec/rebase_originally_empty_spec.cr spec/rebase_abort_retry_spec.cr \
  spec/merge_partial_recovery_spec.cr spec/descriptor_mixed_recovery_spec.cr \
  spec/external_recovery_writer_spec.cr spec/merge_recovery_metadata_spec.cr --error-trace

# Crystal 1.22.2; serialized under the shared validation lock.
flock /workspace/work/git-eol-workflows/validation.lock /bin/bash -c '
source /workspace/toolchains/env.sh
export GC_MARKERS=1 GC_NPROCS=1 CRYSTAL_WORKERS=1
export GIT_ORACLE_BINARY=/workspace/work/git-eol-workflows/git-oracle-stable
CRYSTAL_CACHE_DIR=/workspace/work/git-eol-workflows/cache-replay crystal spec \
  spec/eol*_spec.cr spec/sequencer_spec.cr spec/rebase_spec.cr \
  spec/rebase_originally_empty_spec.cr spec/rebase_abort_retry_spec.cr \
  spec/merge_partial_recovery_spec.cr spec/descriptor_mixed_recovery_spec.cr \
  spec/external_recovery_writer_spec.cr spec/merge_recovery_metadata_spec.cr --error-trace'
```

Passing logs: `/workspace/work/git-eol-workflows/recon-replay/review-matrix-serial-1.13.log` (345 examples, 26.1 seconds) and `review-matrix-locked-1.22.log` (345 examples, 24.61 seconds). The local wrapper executes the absolute pinned Git 2.47.3 with automatic maintenance disabled; the shared wrapper additionally limits pack threads and passes config introspection commands through unchanged. Both wrappers and the underlying absolute oracle returned exactly `git version 2.47.3`. No production source or assertions were changed for the wrappers.

Earlier parallel and unguarded broad attempts hit process exhaustion from approximately 32,400 orphaned Git zombies under container PID 1 (`tail -f /dev/null`), which does not reap children. Those attempts included `fork: Resource temporarily unavailable` in Git fixtures and one compiler codegen fork; they are not counted as code checks. Reducing GC/worker threads, disabling fixture automatic maintenance and using the shared validation lock produced the clean runs above. Failed infrastructure logs remain `review-matrix-1.22.log`, `review-matrix-1.13.log` and `review-matrix-serial-1.22.log` for traceability. No source change was needed between these resource failures and the passing matrices.

Parent and stash received verified new dependency `87fe592`; the private stash preparation seam and its signature are unchanged. Parent scoped re-review and final integrated suites remain pending.

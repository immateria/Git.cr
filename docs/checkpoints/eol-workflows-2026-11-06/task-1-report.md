# Task 1 report

Status: **DONE**

Branch: `feature/eol-workflow-foundation` in `/workspace/work/git-eol-workflows/foundation`.

Base: `1ff359874fc931f33d53aa5fb22fc4913e1fa62b`.

Commit: `e2195ca509cfedc966b9161fcfd41427cf017f71` (`Add shared canonical-to-worktree EOL workflow helpers`).

Full task commit range: `1ff359874fc931f33d53aa5fb22fc4913e1fa62b..e2195ca509cfedc966b9161fcfd41427cf017f71`.

## Changes

Only assigned source/spec files changed:

- `src/git/conversion/workflows.cr`: frozen `for_index`, `materialize`, and `raw_states` interfaces. Planned attribute map selects stage 0 then stage 2, includes explicit nil for absent/nonregular stages and removals, overlays Put/PutStages/Remove, leaves InvalidateStat unchanged, then overlays actual canonical attribute write data at final paths. Marker bytes are stored using bounded/cancellable ordinary loose-blob writes. Materialization copies records/arrays, retains canonical IDs, validates paths/modes/IDs, keeps symlinks raw, enforces per-file/expanded aggregate limits, and polls cancellation. Raw states load bounded canonical blobs, bound aggregate reads and outputs separately, and digest the actual materialized bytes.
- `src/git/conversion.cr` and `src/git/conversion/attributes.cr`: `worktree_fallback : Bool = false` source option. True without a blob map is invalid. Existing map/tree defaults stay exact. Present map keys, including nil, are authoritative. Opt-in absent keys may read worktree attributes, without further index fallback.
- `src/git.cr`: one require after index/merge-plan definitions.
- `src/git/merge/three_way/recovery.cr`: encoding validates canonical write IDs before deriving raw output digests from actual data; decoder/legacy behavior and receipt format stay compatible.
- `src/git/workflow/hard_reset.cr`: resolves one config; always creates target-tree conversion; creates current-attribute conversion only for clean-only admission. Clean-only preflight and old-tree admission compare canonical bytes while write guards retain raw bytes. Canonical-unchanged index/target entries are skipped regardless of stale stats for clean-only operations. Ordinary reset still discards dirty invalid worktree attributes using target rules and preserves its existing stat-dirty rematerialization path.
- `spec/eol_workflow_support_spec.cr`: 19 new examples covering SHA1/SHA256 planned sources, explicit deletion, ours-stage selection, absent-only fallback, actual conflict marker bytes, final relocated matching, canonical versus raw identities, symlinks, expansion/per-file/read/output bounds, cancellation, receipt ID validation, clean CRLF fast-forward, target conversion, unchanged canonical paths, and a clean-equivalent raw race under the index lock.

No push, subagents, source changes outside ownership, or index/ref/worktree publication by the helpers (apart from permitted ordinary loose attribute objects).

## Red evidence

1. Before implementation, ran `crystal spec spec/eol_workflow_support_spec.cr` with the first six receipt/fast-forward regressions. Result: **6 examples, 2 failures, 4 errors**. Receipts returned canonical instead of raw digests on SHA1/SHA256, and clean CRLF predecessors were rejected by clean-only reset.
   Log: `/workspace/work/git-eol-workflows/logs-foundation/red-runtime.log`.
2. Added the helper regressions before implementing helpers and ran the same command. Compilation failed as expected with `undefined method 'for_index' for Git::Conversion.class`.
   Log: `/workspace/work/git-eol-workflows/logs-foundation/red-helpers.log`.
3. During green preparation, corrected a fixture's use of protected `Repository#object` to public `read_object` and corrected its RawObject-versus-tuple assertion to assert the exact returned data. No behavior expectation was relaxed. The intermediate assertion output is retained in `/workspace/work/git-eol-workflows/logs-foundation/intermediate-fixture-assertions.log`.

## Final verification

Every run sourced `/workspace/toolchains/env.sh`, then set:

```sh
export CRYSTAL_CACHE_DIR=/workspace/work/git-eol-workflows/cache-foundation
```

Pinned oracle asserted explicitly with Python `subprocess.check_output`, comparing both `GIT_ORACLE_BINARY` and `/workspace/toolchains/git-2.47.3/bin/git --version` against the exact path and `git version 2.47.3`. `GitOracle` also enforces this version at test startup. Compiler versions were recorded as Crystal 1.22.2 and 1.13.0.

Toolchain log: `/workspace/work/git-eol-workflows/logs-foundation/toolchains.log`.

For Crystal 1.22.2:

```sh
crystal spec spec/eol_workflow_support_spec.cr spec/eol_conversion_spec.cr spec/eol_checkout_spec.cr spec/eol_budget_spec.cr spec/eol_warning_spec.cr spec/eol_worktree_spec.cr spec/hard_reset_spec.cr spec/merge_fast_forward_spec.cr spec/merge_recovery_metadata_spec.cr
```

Result: **134 examples, 0 failures, 0 errors, 0 pending**, 3.52 seconds runtime.
Log: `/workspace/work/git-eol-workflows/logs-foundation/focused-1.22.2.log`.

For Crystal 1.13.0:

```sh
/workspace/toolchains/crystal-1.13.0/bin/crystal spec spec/eol_workflow_support_spec.cr spec/eol_conversion_spec.cr spec/eol_checkout_spec.cr spec/eol_budget_spec.cr spec/eol_warning_spec.cr spec/eol_worktree_spec.cr spec/hard_reset_spec.cr spec/merge_fast_forward_spec.cr spec/merge_recovery_metadata_spec.cr
```

Result: **134 examples, 0 failures, 0 errors, 0 pending**, 3.42 seconds runtime.
Log: `/workspace/work/git-eol-workflows/logs-foundation/focused-1.13.0.log`.

Both compiler lanes passed formatting:

```sh
crystal tool format --check src/git.cr src/git/conversion.cr src/git/conversion/attributes.cr src/git/conversion/workflows.cr src/git/merge/three_way/recovery.cr src/git/workflow/hard_reset.cr spec/eol_workflow_support_spec.cr
/workspace/toolchains/crystal-1.13.0/bin/crystal tool format --check src/git.cr src/git/conversion.cr src/git/conversion/attributes.cr src/git/conversion/workflows.cr src/git/merge/three_way/recovery.cr src/git/workflow/hard_reset.cr spec/eol_workflow_support_spec.cr
```

Logs: `/workspace/work/git-eol-workflows/logs-foundation/format-1.22.2.log` and `/workspace/work/git-eol-workflows/logs-foundation/format-1.13.0.log` (empty output, successful status).

`git diff --check` passed. Log: `/workspace/work/git-eol-workflows/logs-foundation/diff-check.log`.
Commit/stat and final clean branch status: `/workspace/work/git-eol-workflows/logs-foundation/commit.log` and `/workspace/work/git-eol-workflows/logs-foundation/status.log`.

## Concerns and integration boundaries

No frozen-interface changes or unresolved task concerns. Crystal 1.22.2 emits four existing `IO::Memory.new(writeable:)` deprecation warnings in `src/git/object/pack_files.cr`; those files are outside task ownership and the warnings do not affect the successful focused run. Full suites remain the parent's integration gate as requested. Merge/replay/stash callers must pass canonical plans after relocation to `for_index` and `materialize`, and use `raw_states` for immutable recovery destinations rather than re-cleaning raw receipts.

## Parent-approved follow-up: partial-map index fallback and zero budget

Status: **DONE**.

The parent approved a source-policy extension required by stash's selected `keep_index` behavior, based on the pinned oracle, after the original foundation handoff. Constructor option `worktree_index_fallback : Bool = false` now flows through Conversion to Attributes. It is valid only with a blob map and `worktree_fallback: true`. For absent map keys, secure worktree reading takes precedence and the existing bounded index attribute reader is consulted only when working attributes are absent and the new flag is true. Present blob/nil keys suppress both fallback sources. `Conversion.for_index` retains the false default and therefore never consults entries outside its complete supplied projection.

The parent also requested explicit coverage for fully reserved tracked-output budgets: empty materialization/state maps accept `max_total_bytes: 0`, and nonempty bytes fail that zero budget. Existing helper implementation already had the correct behavior; this follow-up adds tests.

Follow-up commit: `8d6309702ea47693f837d4be44fc090f43d49f78` (`Allow explicit index fallback for partial attribute maps`).

Follow-up range: `e2195ca509cfedc966b9161fcfd41427cf017f71..8d6309702ea47693f837d4be44fc090f43d49f78`.

**Final complete task range:** `1ff359874fc931f33d53aa5fb22fc4913e1fa62b..8d6309702ea47693f837d4be44fc090f43d49f78` (two commits).

Files in follow-up: `src/git/conversion.cr`, `src/git/conversion/attributes.cr`, and `spec/eol_workflow_support_spec.cr` only. Added four examples, bringing support coverage to 23 examples. Cases cover absent worktree -> index fallback, working precedence, present nil/blob authority, unchanged exact-map defaults, `for_index` projection isolation, invalid constructor combinations on both types, and zero budgets.

Red evidence: before implementation, the support spec failed compilation with `no parameter named 'worktree_index_fallback'`. Log: `/workspace/work/git-eol-workflows/logs-foundation/red-partial-source-policy.log`.

Re-ran the exact focused commands and format commands documented above, with the same sourced environment, cache directory, and pinned oracle. Final results:

- Crystal 1.22.2: **138 examples, 0 failures, 0 errors, 0 pending**, 3.2 seconds. Log: `/workspace/work/git-eol-workflows/logs-foundation/focused-partial-source-1.22.2.log`.
- Crystal 1.13.0: **138 examples, 0 failures, 0 errors, 0 pending**, 3.89 seconds. Log: `/workspace/work/git-eol-workflows/logs-foundation/focused-partial-source-1.13.0.log`.
- Both format checks passed. Logs: `/workspace/work/git-eol-workflows/logs-foundation/format-partial-source-1.22.2.log` and `/workspace/work/git-eol-workflows/logs-foundation/format-partial-source-1.13.0.log`.
- `git diff --check` passed. Log: `/workspace/work/git-eol-workflows/logs-foundation/diff-check-partial-source.log`.

No unresolved concerns; the same pre-existing Crystal 1.22.2 deprecation warnings remain. The follow-up is approved and does not change the frozen workflow helper signatures. Final branch worktree is clean.

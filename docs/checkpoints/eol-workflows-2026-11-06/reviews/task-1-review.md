# Task 1 review — shared EOL workflow foundation

Spec compliance: ✅ for the Task 1 requirements and approved source-policy extension.

Task quality: **Approved**.

No actionable correctness, safety, compatibility, or maintainability finding was identified in the reviewed change. There are no prioritized fixes to request.

## Scope and method

Read `task-1-brief.md` first, then `task-1-report.md`, the Binding contract and Shared interfaces in `design.md`, and the immutable diff package `reviews/task-1.diff.md`. Reviewed the complete task range `1ff359874fc931f33d53aa5fb22fc4913e1fa62b..8d6309702ea47693f837d4be44fc090f43d49f78` (two commits, seven assigned files). The foundation checkout's HEAD matches the packaged head and its worktree was clean at inspection.

Outside-diff reads were limited to concrete shared-contract risks: conversion output-size enforcement, existing attribute-reader security/budgets and default source behavior, native loose-object writing, checkout clean-preflight/raw publication guards, receipt decoding, and path validation. No source, index, or HEAD mutations, subagents, broad test runs, or repeated diff sweeps were performed. This report is the only written artifact.

## Requirement assessment

| Requirement | Assessment and evidence |
| --- | --- |
| Frozen helper APIs and root availability | ✅ `Conversion.for_index`, `materialize`, and `raw_states` match the required parameter/return contracts. The root require follows the index and merge plan definitions. |
| Planned attribute authority | ✅ `workflows.cr:15–37` selects stage 0 before stage 2, represents nonregular or unavailable selected stages with nil, applies Put/Remove/PutStages, and leaves InvalidateStat without source effect. Explicit nil suppresses fallback. |
| Actual attribute marker data and final paths | ✅ `workflows.cr:39–54` overlays `write.data` at each final write path through bounded, cancellable native `write_blob`; it does not assume the canonical write ID identifies marker data. Only permitted loose objects are published. |
| Constructor defaults and fallback extension | ✅ `attributes.cr:30–41,103–119` preserves exact map/tree defaults, rejects invalid fallback combinations, and permits worktree/index fallback only for absent map keys. Present nil/blob keys remain authoritative. `for_index` enables worktree fallback while leaving index fallback false. The existing descriptor-based reader and bounded index reader are reused. |
| Canonical writes and materialized bytes | ✅ `workflows.cr:58–72` constructs a new array of records, retains canonical path/mode/oid, converts regular-file bytes, preserves symlink bytes, validates file modes/paths/IDs and input size, and checks expanded aggregate output. Existing `Conversion#checkout` checks expanded per-file size before allocation. |
| Immutable raw state projection | ✅ `workflows.cr:77–98` performs bounded blob reads, checks referent type, separately bounds aggregate reads and expanded outputs, retains modes, digests actual raw output, and leaves input maps and publication state unchanged. Empty maps/writes accept zero total budget; nonempty bytes do not. Cancellation is polled around processing and inside existing bounded conversion/object helpers. |
| Receipt correction and compatibility | ✅ `recovery.cr:35–44` validates each canonical write ID before hashing actual write data. Existing receipt format, identity/path/mode/count/byte validation, raw output ownership, and legacy decode behavior remain intact. No conversion is introduced into receipt decoding. |
| Fast-forward clean admission and guards | ✅ `hard_reset.cr:39–56,99–125,147–167` uses one resolved config, creates a current-attribute converter only for clean-only operations, compares canonical current states with HEAD, uses target rules for output, and retains raw observations for publisher overwrite/removal guards. Canonical-unchanged paths skip rematerialization regardless of stale stats in clean-only mode. |
| Ordinary hard reset behavior | ✅ The non-clean-only path does not construct or consult a current worktree attribute source; it continues to use target attributes and preserves stat-dirty rematerialization and stat invalidation behavior. Existing hard reset restrictions and publication error handling are retained. |
| Native implementation and compiler floor | ✅ Changed production code introduces no Git/process execution and uses APIs evidenced by the successful Crystal 1.13.0 and 1.22.2 focused logs. Both installed compiler versions and the exact pinned oracle version were also checked directly during this review. |
| Required regressions and verification | ✅ New examples cover the requested planned attributes, marker bytes, deletions/stages, relocated matching, canonical/raw identities, raw symlinks, expanded budgets, cancellation, invalid receipt IDs, clean CRLF fast-forward, unchanged canonical paths, and a clean-equivalent raw race. Follow-up examples cover partial source policy and zero budgets. |

## Verification evidence

Inspected the saved red logs rather than treating report claims alone as proof:

- `logs-foundation/red-runtime.log`: six examples with two failures and four errors; raw receipt IDs differ from canonical IDs, and clean CRLF predecessors fail before the implementation.
- `logs-foundation/red-helpers.log`: missing `Conversion.for_index` compilation failure.
- `logs-foundation/red-partial-source-policy.log`: missing `worktree_index_fallback` parameter compilation failure.

Inspected the final focused logs:

- `logs-foundation/focused-partial-source-1.22.2.log`: **138 examples, 0 failures, 0 errors, 0 pending**.
- `logs-foundation/focused-partial-source-1.13.0.log`: **138 examples, 0 failures, 0 errors, 0 pending**.
- Toolchain log identifies Crystal **1.22.2**, Crystal **1.13.0**, the dedicated foundation cache, and `/workspace/toolchains/git-2.47.3/bin/git` reporting exactly **git version 2.47.3**. Direct read-only version commands confirmed those versions in the review environment.
- The report records both compiler format checks and `git diff --check` passing; the saved final diff-check log is empty. No focused suite was rerun because code inspection and existing results left no unresolved correctness question requiring a new probe.

The four `IO::Memory.new(writeable:)` deprecation warnings in `src/git/object/pack_files.cr` are unchanged baseline noise outside this task. They do not warrant an unrelated change.

## Cross-task limits

This is approval of the shared foundation, not approval of the final integrated branch. This diff cannot verify that merge/replay/stash callers always pass complete final relocated canonical plans, reserve supplemental expanded output before publication, retain raw ownership throughout abort/skip/retry, forward configuration through every continuation, or preserve stash-specific cleanup/source timing. Those obligations belong to their stream reviews and integration testing.

Full suites on both compilers, the fresh native consumer with Git absent from PATH, and final adversarial integration review are also outside this Task 1 gate. No claim of their completion is made here.

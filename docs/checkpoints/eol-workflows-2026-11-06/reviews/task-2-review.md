# Task 2 review — merge and fast-forward EOL integration

Spec compliance: ✅ for the Task 2 stream and its supported canonical merge surface.

Task quality: **Approved**.

No actionable correctness, safety, compatibility, or maintainability finding was identified in the reviewed diff. There are no prioritized fixes to request.

## Scope and method

Read `task-2-brief.md` first, followed by `task-2-report.md`, the immutable `reviews/task-2.diff.md`, and the Binding contract and Shared interfaces in `design.md`. Reviewed the exact range `8d6309702ea47693f837d4be44fc090f43d49f78..5804533b7b81f81e8a336558aac087fb0ee7c29a`: commits `a3d271c` and `5804533`, six assigned files, 502 insertions and 27 deletions. The merge checkout HEAD matches the packaged head and its worktree was clean at inspection.

Reviewed every production hunk and all 50 new examples. Outside-diff reads were limited to named integration risks: the already-approved conversion helpers, checkout clean admission and raw publication checks, merge recovery ownership and receipt handling, the fast-forward hard-reset caller, initial pull population, directory relocation, and index-only merge continuation. This is not a second whole-branch foundation review. No source/index/ref mutations, subagents, or test-suite reruns were performed. This report is the only written artifact.

## Requirement assessment

| Requirement | Assessment and evidence |
| --- | --- |
| Assigned scope and compatibility | ✅ Changes are limited to `merge.cr`, `merge/fast_forward.cr`, `merge/three_way/initiate.cr`, `merge/three_way/abort.cr`, `remote/pull.cr`, and new `spec/eol_merge_spec.cr`. Existing return types, canonical planning, directory relocation and virtual-base algorithms are retained. |
| Configuration propagation | ✅ `initiate.cr:7–31,55–59`, `fast_forward.cr:14–35,50–52`, `merge.cr:35–40`, `abort.cr:6–12`, and `pull.cr:30–36,47,56,64` expose/resolve the optional configuration and pass the selected object through merge fallback, reset, abort, and all three worktree-changing pull branches. Existing continuation only commits the resolved canonical index and has no conversion-dependent nested operation. |
| Conversion-aware clean admission | ✅ `initiate.cr:82–86,129–130` uses the current worktree attribute source with existing index fallback. The first clean check retains raw observations; the second check validates continued canonical cleanliness without replacing those raw overwrite identities. Genuine dirt remains refused. |
| Final result attribute authority | ✅ `initiate.cr:87–96` completes canonical planning and directory relocation before passing the actual edits and final-path writes to `Conversion.for_index`. The approved helper projects final index attributes, explicit deletions and actual attribute marker writes. Regular writes are then materialized under those final rules. |
| Canonical IDs and unchanged paths | ✅ Materialization creates separate writes retaining canonical mode/path/OID; `plan.edits` remains canonical. Only planned writes are converted, so attribute-only changes do not cause unchanged canonical files to be rewritten. Symlink bytes remain raw and the existing symlink preflight stays before publication. |
| Raw overwrite and removal guards | ✅ `initiate.cr:143–159` uses the original raw clean-check observations for blocking removals, ordinary writes and trailing removals. New/relocated destinations retain nil predecessors and collision protection. The descriptor-based publisher compares exact raw state after callbacks. |
| Output bounds and publication boundary | ✅ `initiate.cr:95–96` materializes and checks expanded per-file/aggregate output before index locking, ORIG_HEAD, merge metadata, worktree or ref publication. Fast-forward passes the selected config into the approved bounded clean-only reset path. `abort.cr:31–36,53–58` projects bounded raw targets and validates converted restoration data before its publication loop. |
| Abort source and ownership | ✅ `abort.cr:31–34` anchors conversion to the immutable original HEAD tree. Raw projected targets reach recovery observation and `abort.cr:52` uses them for exact skip decisions. Restoration writes preserve canonical OIDs while carrying converted bytes; existing receipt identities, raw observations, legacy receipt decode, unrelated-stage checks, and partial retry ownership remain intact. No observation is cleaned to establish ownership. |
| Cancellation, partial publication and filesystem safety | ✅ Existing callbacks flow into new converters/helpers. Expanded output is prepared before publication; existing guards and partial-publication wrapping remain around publication. Untracked collision, symlink, D/F transition and receipt-state checks continue to use the existing bounded safety paths. |
| Native implementation and compiler floor | ✅ Added production code performs no Git/process execution. Direct version checks confirmed Crystal 1.13.0 and 1.22.2; saved related suites pass on both. The absolute oracle binary reports exactly `git version 2.47.3`. |
| Required regression coverage | ✅ New examples compare raw output and canonical index stages/OIDs against pinned Git for SHA1/SHA256, changed/conflicted/deleted/nested attributes, final relocated path rules, resolved continuation, source-tree abort, unchanged canonical paths, explicit configuration, binary/symlink preservation, raw EOL-only races, unpublished relocated output receipt ownership, and expanded-output refusal before merge metadata. Pull configuration covers initial, fast-forward and divergent branches. |

## Verification evidence

Inspected the saved evidence rather than relying solely on the report:

- `logs/merge-red.log`: **18 examples, 8 failures, 10 errors** at the original baseline. Missing output conversion, rejection of clean CRLF predecessors, and relocated-path output differences are visible. Some conflict failures also include the preexisting canonical marker-shape limitation described below.
- `logs/merge-related-latest.log`: **483 examples, 0 failures, 0 errors, 0 pending**, Crystal 1.22.2, 44.34 seconds.
- `logs/merge-related-minimum.log`: **483 examples, 0 failures, 0 errors, 0 pending**, Crystal 1.13.0, 46.05 seconds.
- Direct read-only checks confirmed `/workspace/toolchains/git-2.47.3/bin/git --version`, both installed compiler versions, `git diff --check` on the exact task range, and the Crystal 1.22.2 format check on all six task-owned files.

No additional focused runtime probe was needed: the inspected implementation and existing focused evidence left no concrete unresolved doubt warranting a rerun of the reported suites.

## Baseline limitations and cross-task gates

The canonical text merge already differs from Git on some partially conflicting multiline alignment cases: native fallback can mark a whole file where Git emits a smaller conflicting hunk. This diff does not change that algorithm. The new conflict EOL fixtures use one-line conflicts whose canonical marker shapes match the oracle; clean fixtures still exercise multiline merging. Narrowing the EOL comparison to that supported canonical surface does not establish broader text-alignment parity. The red log must not be represented as containing only EOL defects.

The four `IO::Memory.new(writeable:)` deprecation warnings in `src/git/object/pack_files.cr` in the latest related log are unchanged baseline noise outside this diff.

Cross-task verification: **cannot verify from this diff** the replay/stash callers, integrated supplemental budget reservation, all integrated recovery/configuration interactions, final full suites on both compilers, the fresh native consumer without Git on PATH, or the final adversarial integration review. Those remain parent/integration gates. The initial pull checkout retains its existing population/publication algorithm; this review approves the requested configuration forwarding and does not claim a redesign or global transactional guarantee for that preexisting path.

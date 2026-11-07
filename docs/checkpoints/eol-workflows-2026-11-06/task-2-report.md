# Task 2 — merge / fast-forward EOL integration

Status: DONE — implementation and targeted verification complete; parent task/quality review pending before integration.

Worktree: `/workspace/work/git-eol-workflows/merge`
Branch: `feature/eol-merge`
Foundation base: `8d6309702ea47693f837d4be44fc090f43d49f78`
Task commits after foundation:

- `a3d271c` — Implement merge and fast-forward EOL conversion workflow integration.
- `5804533` — Cover merge recovery boundaries and pull conversion configuration.

Only assigned paths changed: `src/git/merge.cr`, `src/git/merge/fast_forward.cr`, `src/git/merge/three_way/initiate.cr`, `src/git/merge/three_way/abort.cr`, `src/git/remote/pull.cr`, and new `spec/eol_merge_spec.cr`. No shared conversion, receipt, reset, file-plan, rename, text-merge or virtual-base source changed.

## Behavior and contract

Merge, fast-forward and pull accept optional `config:`. Internal entries resolve the selected configuration once and pass the same value through fast-forward fallback and nested reset/populate/merge calls. Merge abort accepts and resolves `config:`. Merge continuation remains unchanged because it only commits the canonical resolved index and never writes working files.

Three-way initiation admits clean converted files through current worktree attributes with index fallback. The initial clean check supplies raw observations retained for overwrite and removal guards. The canonical plan and directory relocation finish before `Conversion.for_index` derives final planned attributes. Materialization changes only already-planned regular writes, retaining canonical blob/index identities and symlink bytes. Expanded per-file and aggregate limits are checked before operation metadata, worktree or refs are written. Blocking and trailing removals both use raw predecessor observations.

Abort derives exact raw original-tree states from a converter anchored to the original HEAD tree. Those exact states participate in recovery ownership and skip decisions; observations are never cleaned to prove ownership. Restoration converts regular output data while retaining canonical index targets. Persisted raw output receipts come from the foundation helper.

## Evidence and tests

Pinned oracle explicitly asserted: `/workspace/toolchains/git-2.47.3/bin/git --version` = `git version 2.47.3`.

- Initial runtime red evidence at baseline `1ff3598`: 18 examples, 8 failures and 10 errors. Missing CRLF conversion, dirty-CRLF admission failures and relocated-path conversion are visible in `/workspace/work/git-eol-workflows/logs/merge-red.log`.
- Focused final suite on Crystal 1.22.2: 50 examples, 0 failures, 0 errors. Log: `/workspace/work/git-eol-workflows/logs/merge-focused-latest.log`.
- Related final suite on Crystal 1.22.2 (1447d239f, LLVM 22.1.3): 483 examples, 0 failures, 0 errors (44.34 seconds). Log: `/workspace/work/git-eol-workflows/logs/merge-related-latest.log`.
- Identical related final suite on Crystal 1.13.0 (6831e441f, LLVM 18.1.6): 483 examples, 0 failures, 0 errors (46.05 seconds). Log: `/workspace/work/git-eol-workflows/logs/merge-related-minimum.log`.
- `crystal tool format --check` for all task-owned files: passed.
- `git diff --check`: passed.

Related command, run with each compiler and its own cache:

```sh
crystal spec spec/eol_merge_spec.cr spec/eol_checkout_spec.cr spec/eol_workflow_support_spec.cr spec/merge*_spec.cr spec/porcelain_spec.cr spec/workflow_reflog_spec.cr
```

The 50 new examples cover SHA1/SHA256 clean and conflict output with LF/CRLF result changes; conflicted/deleted/nested attributes; canonical resolved continuation; source-tree abort and canonical-equivalent abort input; path-specific D/F relocation conversion; explicit config through merge, direct fast-forward, merge fast-forward fallback, and all three pull branches; unchanged canonical-file preservation; genuine dirty refusal; merge and fast-forward EOL-only racing replacements; exact raw receipt authority for interrupted relocated CRLF output; per-file/aggregate expansion refusal before metadata; binary blobs and symlink targets. Oracle comparisons check actual index stage IDs and bytes as well as filesystem results.

## Limit carried forward

Pinned Git probes found a preexisting canonical marker-shape difference for partially conflicting multi-line texts: native fallback emits whole-file conflict markers where Git can emit a compact conflicting hunk. This task does not change that algorithm. Conflict EOL comparisons use one-line conflicts whose canonical marker shapes already match Git byte-for-byte; clean merges still exercise multi-line merging. The initial red log includes the older partial-hunk fixtures, subsequently narrowed to the supported canonical marker surface as requested by the parent.

No uncommitted files, pushes, or known implementation concerns. Parent owns full repository matrix, native-consumer evidence and exact-diff task/quality review before integration.

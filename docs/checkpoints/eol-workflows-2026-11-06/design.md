# EOL conversion for merge, replay and stash

The user approved three parallel workstreams, isolated checkouts, a shared conversion/recovery contract, sequential integration and final adversarial review. This design records that selected approach; implementation details below are engineering choices within that authorization.

Goal: extend the native EOL converter already shipped at 1ff3598 to fast-forward and three-way merge, cherry-pick/revert/rebase, and stash save/apply/pop. Store canonical object/index IDs, materialize configured regular-file working bytes, preserve raw identities for overwrites and recovery, and retain the current bounded native workflow surface.

Alternatives considered: serial implementation would delay independent workflow work; separate converters per workflow would duplicate semantics and risk inconsistent recovery. Selected: shared helpers with one owner and three isolated workflow branches, followed by sequential integration. Stash tracked application delegates to the sequencer, so its final apply tests must run after replay is available.

## Binding contract

- Crystal >=1.13.0; verify 1.13.0 and 1.22.2 on Linux. Git oracle is /workspace/toolchains/git-2.47.3/bin/git, with its exact version asserted. Production native operations must not execute Git.
- Existing public return types and operation limits remain compatible. Add config: Config? = nil to worktree-changing entrypoints and forward through all nested operations and continuations. Resolve config once per entry; default repository-local conversion configuration only. Expose optional warning: Proc(String, Nil)? on stash capture for safecrlf=warn; failures precede publication.
- Clean preflight uses current worktree attributes with index fallback. Its result is RAW observations; canonical equality permits clean CRLF but never authorizes overwrite by canonical equality alone.
- Merge/replay output conversion runs after plan_files AND directory relocation, uses final paths and planned result attributes, and converts only writes already selected by the canonical plan. It must not rewrite an unchanged blob for attributes-only updates.
- Derive planned attributes from index stage0/ours stage2, apply index edits, then overlay actual attribute write data (including conflict markers). Deletions are explicit nil. Unmapped attribute paths fall back to the current worktree (checkout index-first semantics); explicit nil blocks fallback. Binary/non-regular attributes do not become text sources. Virtual merge-base synthesis stays canonical.
- Checkout::Write.oid and Index edits remain canonical; Write.data becomes materialized output. Symlink data remains raw. Output byte limits include CRLF expansion BEFORE metadata, worktree or reference publication.
- Recovery receipts record ObjectId.digest("blob", write.data, format), NOT canonical Write.oid. Preserve operation identity, raw guards, legacy read support and retry refusal for unowned or changed outputs. Never clean a file to prove ownership during recovery.
- Abort/skip destination conversion uses the immutable original/target tree. Admit exact raw predecessor, persisted output and planned restoration identities only, with bounded provenance. Recovery entry limits count the distinct path union across predecessor/target maps; allow two raw identities per logical path with an overflow-safe <=2*max_entries record bound and the existing combined byte cap. Rebase retry must account for converted original/target states rather than canonical IDs. Configuration changes must not silently broaden ownership to clean-equivalent unrelated bytes.
- Stash splits canonical saved maps from raw observed maps. Capture via worktree attributes; safecrlf checks changed tracked captures and new captures. Cleanup source differs by full/default, keep_index, staged_only and selected-path operation; pinned Git probes decide ambiguous timing. Tracked apply uses sequencer; untracked attributes may come from the third parent and need planned source overlays before publication. Canonical no-op detection and raw publication guards remain separate.
- Preserve path scope, ignore behavior, byte/entry budgets, cancellation, partial-publication errors, stat safety, symlink behavior and existing recovery semantics. Treat callbacks as arbitrary user code; do not cache unchecked post-callback stats against earlier content.
- Full wildmatch, external filters, ident, working-tree encodings, gitlink lifecycle and unsupported workflow forms are outside this feature. Do not weaken existing failures to obtain passes.

## Shared interfaces (foundation owner only)

Create src/git/conversion/workflows.cr, required by src/git.cr after index/merge plan definitions:

1. Conversion.for_index(repository : Repository, current : Array(Index::Entry), *, edits : Array(Index::Edit) = [] of Index::Edit, writes : Array(Checkout::Write) = [] of Checkout::Write, config : Config? = nil, max_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608, check : Proc(Nil)? = nil) : Conversion.
   Builds complete planned attribute blob map using the precedence above. Canonical attribute marker writes can be materialized as ordinary loose blobs for parsing, bounded and without index/ref/worktree mutation. Uses worktree fallback only for unmapped paths and does not convert writes itself. Extend Conversion/Attributes constructors with worktree_fallback : Bool = false for blob-map mode; true without a blob map is invalid. Existing default complete-map and tree sources remain unchanged. For partial selected-path stash overlays only, an additional opt-in worktree_index_fallback : Bool = false permits index fallback after an absent worktree file; it requires blob-map mode and worktree_fallback:true. Explicit nil blocks both. for_index leaves this extra flag false so projected planned-index authority stays frozen.
2. Conversion#materialize(writes : Array(Checkout::Write), *, max_total_bytes : Int64, operation : String = "Git checkout") : Array(Checkout::Write).
   New array, preserve path/mode/canonical oid, convert data only for regular modes, enforce per-file and aggregate output bounds, poll cancellation, preserve symlinks.
3. Conversion#raw_states(states : Hash(String, Checkout::FileState), *, max_total_bytes : Int64, operation : String = "Git checkout") : Hash(String, Checkout::FileState).
   Project canonical tree states into exact materialized raw IDs under this converter. Load blobs boundedly; bound aggregate reads and outputs, keep symlinks raw. Does not mutate source states, index, refs or worktree.

Recovery.encode must retain canonical write ID validation and encode raw data digests, with existing receipt format and legacy decoding preserved. Hard-reset's clean_only path must gain conversion-aware clean preflight, raw observations and target-tree output conversion so fast-forward can reuse it. No removal of ordinary reset safety checks.

## Replay/stash private preparation seam

Replay owns optional `prepare_worktree : Proc(Array(Index::Entry), Merge::FilePlan, Int64)? = nil` on private sequencer_start. Invoke exactly once after the complete canonical plan and relocation, before tracked conversion, metadata or any publication. The closure sees current index plus final canonical plan, prepares and materializes stash untracked outputs under planned tracked attributes plus third-parent attribute overlays, and returns the remaining byte budget for tracked materialization. Validate returned budget is within 0..max_total_bytes. Default nil means full max_total_bytes. No public result type changes. Third-parent attributes affect ONLY later untracked restoration, NEVER tracked sequencer outputs (pinned Git proof). Stash passes the total budget rather than subtracting raw untracked bytes twice; the hook reserves expanded supplemental bytes. Both tracked and untracked expansion must be rejected before tracked publication. Stash may use this private seam without changing sequencer files itself; final apply tests wait for replay.

## Ownership

Foundation: conversion/workflows.cr, conversion.cr and conversion/attributes.cr source-policy option, src/git.cr require, merge/three_way/recovery.cr receipt encoding, workflow/hard_reset.cr clean_only support, spec/eol_workflow_support_spec.cr.
Merge: merge/fast_forward.cr, merge/three_way/{initiate,abort,continue}.cr as needed, merge.cr public facade, remote/pull.cr config forwarding, spec/eol_merge_spec.cr.
Replay: workflow/sequencer.cr + sequencer/*, workflow/rebase.cr + rebase/*, spec/eol_replay_spec.cr and focused recovery regressions.
Stash: workflow/stash.cr + stash/*, spec/eol_stash_spec.cr.
Integration owner: plan/ledger, docs, worktree management, shared-interface changes, sequential cherry-picks, full matrix, consumers and reviews. Any shared-interface change must be coordinated before editing.

## Acceptance

Each stream proves failures before fixes and positive runtime behavior against pinned Git for SHA1/SHA256; includes binary/symlink preservation, explicit/default config, conflicted/deleted/nested attributes, unchanged canonical paths, raw EOL-only races and expanded-budget refusal before side effects. Merge/replay include continue/abort/skip and interrupted recovery. Stash includes cleanup variants, saved trees/parents, apply/pop/index, conflicts and safecrlf diagnostics. Review each task with its exact diff, integrate one at a time, then full suite on both compilers, fresh native consumer without Git on PATH and final adversarial review with fixes/rechecks.

## Review clarification: retry and initial rebase preparation

Restoration-started state must remain distinguishable after losing both a restoration receipt and its companion marker; bind that fact into durable core operation state before restoration writes. Missing pair cannot silently become a fresh attempt after interruption. Initial onto EOL materialization and its output bounds must be prepared before any rebase metadata or ORIG_HEAD update, including when ORIG_HEAD already exists. The distinct-path union rule above preserves existing n-file capacity while bounding both map frames; disjoint maps whose union exceeds max_entries are rejected.

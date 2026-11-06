# Merge Parity Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extend the shared native merge engine with rename and directory conflict states, recursive merge bases, and edited-file rename detection.

**Architecture:** Keep conflict planning in Git::Merge and publication in Repository entrypoints. Reuse the planner for sequencer operations. Build virtual bases using immutable objects only; never publish their refs or indexes.

**Tech Stack:** Crystal >= 1.13.0; Git 2.47.3 differential oracle; no new dependencies.

**Spec:** User-approved milestone in this conversation: rename/file-directory conflict states, multiple merge bases, similarity rename detection, and accurate coverage documentation.

## Global Constraints

- Preserve explicit budgets, cancellation, untracked-file protection, and partial-publication diagnostics.
- No implicit Git subprocesses in production.
- Test SHA-1 and SHA-256; compare index stages and filesystem outcomes to Git 2.47.3.
- Use the existing isolated checkout. No environment configuration or publishing changes.

## Review Focus

- Relocation names colliding with tracked or untracked paths must never overwrite data.
- Abort must restore directory transitions and reject unrelated staged paths.
- Rename pairing must be deterministic and bounded, including ambiguous candidates.
- Recursive base construction must have bounded recursion and honor cancellation.
- New blob writes may survive failed preflight, but refs/index/operation state must remain untouched.

### Task 1: Conflict states and recovery

Files: src/git/merge/three_way/renames.cr, src/git/merge/plan.cr, src/git/merge/three_way/abort.cr, src/git/workflow/sequencer/{replay,abort}.cr; focused specs.
Interfaces: preserve FilePlan and RenamePlan contracts; extend plan_files inputs for side labels as needed.
- [x] Add oracle tests for divergent rename destinations, destination collisions, both orientations of file/directory conflicts, abort/continue, and unsafe relocation destinations. Observe failures.
- [x] Implement index-stage and worktree conflict planning, then extend abort to restore structural transitions.
- [x] Run focused merge and sequencer specs; inspect the diff.

### Task 2: Recursive merge bases

Files: new src/git/merge/three_way/bases.cr, initiate.cr, three_way.cr; spec/merge_bases_spec.cr.
Interfaces: internal virtual base builder returns a commit OID for use by the existing merge flow. Only immutable object writes are allowed.
- [x] Add criss-cross oracle fixtures with clean and conflicting intermediate bases and budget/cancellation checks. Observe failures.
- [x] Recursively combine common ancestors, then use the resulting tree for the outer merge. Preserve unrelated-history rejection.
- [x] Run recursive-base and existing merge/history specs.

### Task 3: Edited-file rename detection

Files: new src/git/merge/three_way/similarity.cr, renames.cr, plan.cr, merge/sequencer call sites; spec/merge_similarity_spec.cr.
Interfaces: rename_plan accepts Repository and explicit read/work budgets; exact matches precede bounded similarity pairing.
- [x] Add oracle fixtures for rename+edit with independent changes, binary inputs, below-threshold and ambiguous candidates, modes, replay, and limits. Observe failures.
- [x] Add deterministic 50% content similarity matching and merge renamed content against the correct ancestor. Never silently discard either edit.
- [x] Run affected specs and format checks.

### Task 4: Documentation and final verification

Files: README.md, docs/{PARITY_LEDGER,CORE_FUNCTION_COVERAGE,ORACLE_FIXTURES}.md.
- [x] Reconcile stale branch/revision/merge claims with implementation and tested support.
- [x] Run crystal tool format --check on changed source and crystal spec with loopback access.
- [x] Get a fresh whole-change code review; fix substantive findings with regression coverage.

## Execution record

Initial HEAD: c97b77ef56d07cf71fc746b0a6563e9bd43c4ec5. Checkout initially clean.
Ruling: Execute directly after the user's "do it"; no separate approval pause or worktree. Keep changes reviewable without publishing.

Task 1: implemented. Oracle tests first exposed divergent rename and D/F rejection; shared planning now records the conflicts and durable recovery paths. Tracked suffix collision and untracked refusal match Git. Index stages preserve merged content. Abort restores structural transitions and rejects unrelated staged entries.
Task 2: implemented. Two/three-base criss-cross tests include conflicted text bases, tied timestamps, renamed conflict paths, binary add/add and missing final newlines. Recursive synthesis uses traversal ordering and logical stages, writing immutable objects only.
Task 3: implemented. Independent edits across renamed files pass merge/cherry-pick/rebase/revert checks. Binary content, common/divergent destinations, rename/add, ambiguity, symlinks, byte/comparison limits and cancellation have focused coverage.
Task 4: documentation reconciled and fresh reviewer completed. All three substantive findings were reproduced in permanent specs, observed RED, fixed and observed GREEN (46 focused checks). The stale exact-phase comment was also corrected. Full-suite and final formatting results pending below.

Implementation decisions: retain the existing bounded text marker model and fail closed for unresolved-source rename/add and virtual-base D/F conflicts. Full ort candidate/attribute policy, copies and directory renames remain outside this milestone. These limits are documented in README and the coverage ledger. Only the installed Crystal 1.22.2/Linux x86-64 lane is being verified; compiler-floor and macOS lanes are not available here. No environment draft or publication changes.

Final verification: Crystal 1.22.2 / Git 2.47.3, Linux x86-64. `crystal spec`: 855 examples, 0 failures, 0 errors, 0 pending (59.99 seconds execution). Four pre-existing IO::Memory deprecation warnings. Changed-source `crystal tool format --check` and `git diff --check` pass. All work remains reviewable on feat/merge-parity without pushing or publishing.

## Follow-up quality pass

The user requested a quality pass over the implementation. Independent reviews
covered recursive bases and recovery; a deterministic rename sweep supplemented
the permanent oracle fixtures. Confirmed defects were reproduced before fixes:

- Two-source rename collisions replaced an already-merged contribution with
  the original HEAD blob. Destination composition now preserves both sources.
- Virtual symlink/type conflicts reused a blob with the wrong mode; binary
  replacements reused old symlink content; empty additions and mode-only cases
  missed Git's trivial merge rules. Virtual bases now preserve mode/OID coupling,
  apply trivial OID merges first and use the correct regular-file ancestor.
- Divergent rename markers lost branch/path labels and nesting width. Outer
  merges and recursive folds now supply the correct marker context.
- Abort assumed the index described all worktree writes. A structured output
  receipt and observed filesystem view now recover pre-index publication,
  structural directories and interrupted abort retries, while refusing unrelated
  or modified unindexed output. Legacy two-line/path-only metadata remains
  supported for indexed recovery.
- Initial publication did not bind its saved receipt, and new state did not
  distinguish lost/truncated receipts from legacy metadata. Publication checks
  exact receipt bytes; tagged state requires a structured receipt, and an exact
  output-record count rejects truncation. Metadata opens are nonblocking so
  substituted FIFOs are rejected rather than stranding recovery.

Each reproduced defect has a permanent regression observed RED then GREEN;
protocol and compatibility controls passed alongside them. Independent exploratory sweeps found
no remaining mismatches in 100 rename-operation combinations and 780 virtual-base
combinations after their respective fixes. These runners/logs live outside the
checkout under /workspace/merge-parity/quality; permanent reduced regressions are
in the merge quality/recovery specs and are listed in ORACLE_FIXTURES.md.

This pass also installed the official Crystal 1.13.0 bundle outside the checkout
to verify the declared minimum compiler. No environment configuration was saved,
no repository code was committed or pushed, and nothing was published. Final
full-suite results are recorded below when both compiler lanes complete.

Quality-pass final verification: `crystal spec` passed all 939 examples (0 failures, 0 errors, 0 pending) on both Crystal 1.13.0 / LLVM 18.1.6 and Crystal 1.22.2 / LLVM 22.1.3, with Git 2.47.3 on Linux x86-64. Execution times were 1:09 and 1:05 respectively. Changed-source formatting and `git diff --check` pass. Four existing IO::Memory deprecation warnings remain on Crystal 1.22.2. macOS was not executed in this environment.

## Continuing merge collision coverage

The user requested further improvement. This iteration removes the same-kind
rename/add source-conflict refusal: preserve the source merge (including nested
text markers or binary side selection) as a destination index stage, then apply
the destination add/add merge. Branch/path labels and marker depth travel with
that conflict plan so merge, replay and virtual-base construction remain distinct.
Different source kinds stay explicitly rejected until their type-relocation
semantics are implemented. Existing byte, cancellation, publication and recovery
contracts remain required. Verify fresh oracle fixtures, all existing specs and
both available compiler lanes; retain the branch without publishing.

Continuation evidence: 98 nested-collision cases pass against Git 2.47.3. Initial
fixtures reproduced the old refusal. Binary-original/text-side fixtures caught
incorrect inner text rendering; review regressions caught suppressed outer
markers across mode changes, oversized outer marker fallback, and false
conflicts after intermediate-state equality. A separate structural collision
set prevents equality from resolving rename/delete conflicts. Each reproduced
defect was observed before its fix. Existing affected merge/replay/stash checks
passed (497 examples) before the final review fixes; full final suites follow.

Continuation final verification: `crystal spec` passed 1037 examples with
0 failures, 0 errors and 0 pending on both Crystal 1.13.0 (1:23 execution) and
Crystal 1.22.2 (1:21 execution), Git 2.47.3, Linux x86-64. This iteration adds
98 permanent oracle cases. Changed-source formatting and `git diff --check`
pass. Review findings were reproduced before fixes and covered by the final
suite. Work remains uncommitted on feat/merge-parity; nothing was pushed,
published or saved to environment configuration. Source type changes and full
ort hunk/attribute layout remain explicitly outside this iteration.

## Adversarial review of committed merge work

The user requested a quality/adversarial pass after commit `6cc535c`. Independent
reviews reproduced destination-stage loss in crossed divergent renames and a
recursive reduction that reported a false clean result. Destination contributions
now compose by side and retain structural conflicts even when their merged blobs
are equal. Divergent text sources merge executable modes; binary sources retain
separate real-side blobs for ordinary merges and the original source for virtual
bases. Binary classification includes compatible regular ancestors and excludes
symlink targets when both tips become regular files. Unsupported divergent text
encoding and oversized markers refuse before publication.

Recovery review also reproduced mutable MERGE_HEAD changing commit parents,
blocking FIFO operation metadata opens, and outer rebase abort retries clearing
state before restoring a stale index. Publication binds merge state, continuation
validates and binds receipt identity before committing, operation
metadata opens nonblocking before type validation, and rebase abort reconciles
observed worktree, index and reference states before cleanup. Unrelated worktree
content still refuses restoration. Budget review fixed loose payload envelope
allowance leaking into payload limits, cached packed-base reads bypassing smaller
limits, merge-base traversal ignoring its supplied commit limit, and Int32 envelope
arithmetic overflow.

Permanent reductions cover both object formats. Exploratory checks compared 196
rename/destination/deletion combinations and 216 three-base combinations with
Git 2.47.3. The container's PID 1 accumulated orphan Git children, causing transient
fork failures during checks; final verification uses a child-reaping supervisor
outside the checkout with reduced compiler/GC concurrency. Nothing was pushed
or published.

Adversarial final verification: all 1111 examples pass with 0 failures, 0 errors
and 0 pending on Crystal 1.22.2 (1:31 execution) and Crystal 1.13.0 (1:35 execution),
Git 2.47.3, Linux x86-64. This adds 74 permanent regression examples. Both full
builds used a generated entrypoint requiring all 73 spec files, a single LLVM
module, one compiler worker and one GC marker. The floor compiler build used
one CPU; both final test runs used the normal CPU affinity. Oracle pack/index
workers were capped at one through an external wrapper; config-inspection
commands kept their original arguments to preserve config-scope assertions.
Earlier attempts hit host process/thread limits rather than assertion failures.
The wrapper, supervisor and logs are outside the checkout in /workspace/adversarial.
Changed-source formatting and `git diff --check` pass. Four existing IO::Memory
deprecation warnings remain on Crystal 1.22.2; macOS was not executed. The audit
fixes remain uncommitted after baseline `6cc535c`.

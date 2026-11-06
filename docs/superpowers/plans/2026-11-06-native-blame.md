# Native Blame Implementation Plan

> **For agentic workers:** Use the current session's inline implementation and
> independent diff/oracle reviewers. Track each deliverable below.

**Goal:** Attribute each line of a committed file to its introducing commit,
matching ordinary Git blame within explicit resource limits.

**Architecture:** Carry final-line positions backwards through all commit
parents using the existing byte-oriented xdiff matcher. Resolve whole-file
renames through shared content-similarity scoring; preserve raw line bytes and
separate author/committer identities. Store no refs, index or worktree changes.

**Tech Stack:** Crystal >= 1.13.0, standard library, Git 2.47.3 as test oracle.

**Spec:** User request "work on blame"; public and behavioral contract below.

## Global constraints and public contract

- `require "git"` exposes `Repository#blame(path, revision = "HEAD", ...)`.
- Return `Git::Blame`, an `Indexable(Blame::Line)` with `lines`, resolved
  `revision`, `path` and `scanned` commit count.
- Lines expose `commit_oid`, `original_path`, one-based `original_line` and
  `final_line`, byte-exact `content` including its LF if present, `author` and
  `committer` signatures, and a `boundary?` flag.
- Default traversal considers all parents, follows exact/edited whole-file
  renames at the existing 50% span threshold, and prioritizes an identical
  parent blob before per-line distribution. `first_parent:` restricts traversal;
  `follow_renames: false` restricts it to the same path.
- Root and shallow commits are boundaries. Missing/invalid paths, gitlinks and
  non-commit revisions reject explicitly. Regular files and committed symlink
  contents are read from objects, never through the working filesystem.
- Bound object bytes, cumulative cached bytes, history states, tree entries,
  lines, diff work and cancellation. Budget failure returns no partial result.
- No Git subprocess or new shard dependency in production. No working-tree
  blame, reverse blame, ignored revisions, whitespace-ignore or moved/copied
  line tracking in this iteration. Leave changes uncommitted for review.

## Review focus

- Repeated lines must follow xdiff correspondence rather than quadratic LCS.
- Missing final LF, NUL and invalid UTF-8 must preserve bytes and attribution.
- Merge parents can contribute different lines; whole-blob matches have priority.
- Renames must not turn retained-source copies into historical attribution.
- Read-only operation must respect shallow boundaries, cancellation and budgets
  without depending on index, HEAD changes or working files.

## Deliverables

- [x] Add oracle-first `spec/blame_spec.cr` and byte-safe fixture support;
  observe the missing `Repository#blame` failure before production changes.
- [x] Add bounded `TextDiff.equal_spans` and focused specs in
  `spec/blame_diff_spec.cr`; preserve ordinary patch output and callback cadence.
- [x] Extract cached span scoring into `TreeDiff::Similarity`, leaving merge
  pairing policy and limits intact; prove direct and existing merge fixtures.
- [x] Add `src/git/blame.cr` and focused blame history/walker implementation.
  Add budget/cancellation/read-only regressions and verify the oracle fixtures.
- [x] Review merge ties, renames, byte content and malformed inputs independently;
  reduce every demonstrated mismatch to a permanent regression before fixing.
- [x] Update README and coverage/oracle docs, verify a fresh consuming shard,
  format and diff checks, then run the complete suite on Crystal 1.13.0 and
  1.22.2. Record exact evidence and any unsupported profiles below.

## Verification evidence

Initial oracle exploration covers 24 cases under /workspace/blame-quality/oracle.
The first permanent root-line spec fails because `Repository#blame` is missing
(/workspace/blame-quality/red-compile.log).

The complete focused set contains 63 new examples and passes on both available
compiler lanes. Reduced RED cases caught same-path-parent priority before rename
fallback, the unique-basename 75% shortcut, directory-to-file renames, shared
ancestor accounting, and first-parent/shallow limits on unvisited parent headers.
Each has a permanent SHA-1/SHA-256 regression. Candidate scoring now polls
cancellation before cached comparisons.

A deterministic scratch harness compared previous/current patch hunks and
callback counts across 2000 comparisons (1000 seeded byte pairs, each with both
indent modes) without differences. Fresh path-dependent
consumers compile and execute the exact README blame example on Crystal 1.13.0
and 1.22.2 with no Git executable on PATH. Source/example formatting and local
documentation links pass. The optional native refactor scanner could not be
materialized from its cloud resource; no scanner-verified promotion is claimed.

Final full verification passes all 1174 examples with 0 failures, 0 errors and
0 pending on Crystal 1.22.2 (1:21 execution) and 1.13.0 (1:31 execution),
Git 2.47.3, Linux x86-64. Both builds include all 77 spec files and the same
source/spec snapshot, SHA-256
`eb2440ac55e5738467b64c55e58152dec25277549e656a6f1f21e58bd6dc5439`.
MacOS was not run for this iteration. Four pre-existing IO::Memory deprecation
warnings remain on 1.22.2; the supported-floor build emits none.

Earlier complete floor runs hit upstream Git fork/thread errors, with no
assertion failures. Builds use one compiler thread, a single LLVM module and
reduced GC concurrency; runtimes are unpinned. Current-lane oracle commands cap
client pack/index workers. The final floor run additionally supplies inherited
resource-only configuration to Git's spawned servers; config-inspection commands
retain their fixture-selected global source and original arguments. The
unchanged floor binary then passes the entire suite. No tests were skipped.
Build/runtime logs, wrappers and exploratory sources live outside the checkout
under /workspace/blame-quality. No environment configuration was saved, and
the feature has not been committed or pushed.

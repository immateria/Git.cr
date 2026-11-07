# Task 4 review — stash EOL integration

Reviewed immutable range `d9e2b57459c379200952f6808aea321773ab3179..1ffd545bcbdafd7c10e04e4d7459225dbcd7671b` in `reviews/task-4.diff.md`, the Task 4 brief/report, and the binding design. Read all six changed files. Outside-diff reads were limited to the named attribute-source/snapshot and preparation-hook risks: conversion attribute caching, the shared materializer, stash publication/verification, sequencer entrypoints, and the pinned oracle. No reviewed checkout source, index, HEAD, or refs were changed.

**Spec: ❌. Quality: Needs fixes.**

## Finding

1. **P2 — Warning callback can change an untracked attribute source without rejection, producing a stash that changes file bytes on restore.** `src/git/workflow/stash/save.cr:80` constructs a converter that caches root worktree attributes; `save.cr:102` invokes arbitrary warning code before `save.cr:116` captures untracked files. `src/git/workflow/stash/worktree.cr:109` then cleans those files through the earlier converter, while lines 113–114 record their later raw identities. A callback mutation of an untracked `.gitattributes` is therefore accepted as the original snapshot instead of rejected by the final raw verification.

   Reproduced for SHA-1 and SHA-256: commit `file.txt` with `base\n`; set `core.safecrlf=warn`; create untracked `.gitattributes` containing `*.txt text eol=crlf\n`, tracked `file.txt` containing `working\n`, and untracked `new.txt` containing `new\r\n`. Pass a warning callback which replaces `.gitattributes` with `*.txt -text\n`, then call `stash.push(include_untracked: true)`. Push succeeds and removes `new.txt`; its third parent contains the new `-text` attributes but `new.txt` is stored as `new\n` using the cached old attributes. Applying the stash restores `new\n` under `-text`, losing the original CRLF bytes. The otherwise identical non-mutating callback restores `new\r\n` correctly. This violates the callback/snapshot requirement and the requirement to capture with the worktree attribute source represented by the saved state.

   Freeze raw snapshots of relevant working files and attribute sources before user warning callbacks can run, or defer delivery of warnings until those snapshots are complete; revalidate those same identities before publication. Include attribute sources outside the selected/captured path set when they affected conversion. Add a regression for this attribute-source mutation that refuses before refs/worktree publication and preserves the callback's bytes. Existing same-file and index-mutation warning tests do not exercise a source captured later.

## Other contract checks

The reviewed delta exposes and forwards `config:` through public/protected push/apply/pop, resolves it once at each protected entry, and exposes the capture warning callback. Canonical tracked and third-parent maps are separate from raw observations; the saved index parent remains canonical and complete. Canonical maps drive no-op detection and staged-only inverse merging. Raw identities continue to authorize overwrite/removal, including staged-deletion exclusions. Safecrlf is checked for changed tracked content and new captures, with converter warning deduplication. The early index checksum correctly rejects index mutations by warning callbacks; the finding concerns a worktree attribute source not yet observed.

Cleanup source selection follows the documented full/default HEAD, full keep-index saved-index, selected default original-worktree, selected keep-index projected source, and staged-only worktree policies. Explicit nil and nonregular selected attribute entries prevent inappropriate attribute fallback. Cleanup materialization enforces expanded output limits before stash reference publication, and final raw write filtering avoids unnecessary writes. A suspected raw-equals-canonical selection problem was tested against pinned Git with attributes-only staged changes across full/selected and default/keep-index forms: all four native outputs matched Git, so no finding is raised for that case.

Apply constructs supplemental conversion from the final tracked plan plus third-parent attribute writes and materializes that supplemental output inside the private preparation hook. It returns the budget remaining after expanded supplemental bytes while passing the original total budget to the sequencer. Third-parent attributes are not passed to tracked conversion. Existing destination-wide untracked collision preflight, PartialApply propagation, conflict behavior, canonical index restoration, and drop-after-success behavior remain present. The added BOM regression explicitly compares the third-parent blob-source behavior with pinned Git; it does not change file-source BOM stripping.

No native Git subprocess was introduced. The existing focused logs each report **156 examples, 0 failures, 0 errors, 0 pending** on Crystal 1.22.2 and 1.13.0; these suites were not rerun. Format/diff checks were accepted as reported.

## Focused review evidence

Disposable scripts and logs are under `/workspace/work/git-eol-workflows/review-stash-probes/`; compilation used the isolated `cache-review-stash`. Both scripts load the existing GitOracle, and `callback.log` explicitly records the absolute oracle `/workspace/toolchains/git-2.47.3/bin/git` and asserted exact `git version 2.47.3`.

```sh
source /workspace/toolchains/env.sh
CRYSTAL_CACHE_DIR=/workspace/work/git-eol-workflows/cache-review-stash crystal run /workspace/work/git-eol-workflows/review-stash-probes/probes.cr
CRYSTAL_CACHE_DIR=/workspace/work/git-eol-workflows/cache-review-stash crystal run /workspace/work/git-eol-workflows/review-stash-probes/callback.cr
```

`probes.log`: all four cleanup forms match native/pinned-Git bytes; the initial callback case reproduces the finding. `callback.log`: four controlled cases (SHA-1/SHA-256, callback mutation on/off), exit 0; mutation alone changes restored `new\r\n` to `new\n`. These focused probes ran on Crystal 1.22.2. No whole-suite duplication or production fixes were performed during review.

Replay dependency fixes are owned and reviewed separately. This review does not duplicate findings on unchanged replay files. After the stash-only delta is rebased onto the final replay tip, its consumer tests and dependency integration must be verified again. Final integrated full gates on both compilers, the native consumer without Git on PATH, and final adversarial review remain parent/integration responsibilities.

# Task 4 — stash EOL integration

Completed in `/workspace/work/git-eol-workflows/stash`, branch `feature/eol-stash`.

- Final task-only commit: `1ffd545bcbdafd7c10e04e4d7459225dbcd7671b` — Add native EOL conversion to stash workflows.
- Exact dependency base: replay `d9e2b57459c379200952f6808aea321773ab3179`, built on shared foundation `8d6309702ea47693f837d4be44fc090f43d49f78` / `e2195ca509cfedc966b9161fcfd41427cf017f71`.
- Six owned files changed: public stash facade, stash save/apply/worktree helpers, and two `eol_stash*_spec.cr` files. Worktree clean. No shared source edits, subagents, push, or full-suite duplication.

## Implementation

Public/protected push/apply/pop accept `config:`; push also accepts the safecrlf `warning:` callback. Each entry resolves config once and forwards it through nested work.

Capture cleans tracked and untracked regular files using worktree attributes/index fallback, preserving the complete canonical saved index parent. Raw observations independently authorize snapshot checks and cleanup publication. Canonical maps drive native no-op detection and staged-only inverse merging. Changed tracked/new captures receive safecrlf checks; unchanged LF predecessors do not. Early index checksums prevent warning callbacks from publishing stale index plans, and raw snapshot checks reject callback EOL-only file mutations.

Cleanup materializes bounded writes before publication. Full/default uses HEAD attributes; full keep_index uses index attributes. Selected default and staged-only preserve original worktree attribute timing. Selected keep_index overlays selected regular index attributes on secure worktree-first/index-fallback sources; explicit nil blocks both. Symlink attribute targets never become parsed attribute data.

Apply uses the replay preparation seam before tracked materialization/publication. Supplemental untracked output sees planned tracked attributes plus third-parent attributes; only supplemental output sees third-parent attributes. Expanded supplemental bytes reserve the remaining tracked output budget. Existing untracked collision preflight, PartialApply semantics, canonical index restoration, and pop drop-after-success behavior remain intact.

## Evidence and verification

Pinned oracle: `/workspace/toolchains/git-2.47.3/bin/git`, exact `git version 2.47.3`; enforced by GitOracle at suite startup. Compiler versions: Crystal 1.22.2 / LLVM 22.1.3 and Crystal 1.13.0 / LLVM 18.1.6, Linux x86_64.

Initial semantic red run at baseline `1ff3598`:

```sh
source /workspace/toolchains/env.sh
CRYSTAL_CACHE_DIR=/workspace/work/git-eol-workflows/cache-stash crystal spec spec/eol_stash_spec.cr
```

10 examples: 6 failures, 2 errors. These proved raw saved CRLF blobs, wrong keep_index cleanup bytes, missing canonical no-op, and staged-only canonical merge failure. Log: `/workspace/work/git-eol-workflows/stash-red.log`.

Final focused checks on the exact dependency/source snapshot, then task-only squash/amend without source changes:

```sh
source /workspace/toolchains/env.sh
CRYSTAL_CACHE_DIR=/workspace/work/git-eol-workflows/cache-stash crystal spec spec/stash_spec.cr spec/eol_stash_spec.cr spec/eol_stash_apply_spec.cr
CRYSTAL_CACHE_DIR=/workspace/work/git-eol-workflows/cache-stash-1.13 /workspace/toolchains/crystal-1.13.0/bin/crystal spec spec/stash_spec.cr spec/eol_stash_spec.cr spec/eol_stash_apply_spec.cr
crystal tool format --check src/git/workflow/stash.cr src/git/workflow/stash/*.cr spec/eol_stash_spec.cr spec/eol_stash_apply_spec.cr
git diff --check d9e2b57459c379200952f6808aea321773ab3179
```

Both compiler runs: **156 examples, 0 failures, 0 errors, 0 pending**. This includes 90 existing stash examples and 66 new SHA-1/SHA-256 examples. Logs: `/workspace/work/git-eol-workflows/stash-focused-1.22-final.log` and `stash-focused-1.13-final.log`. Format/diff checks pass. Crystal 1.22 emits the existing unrelated IO::Memory deprecation from object/pack_files.cr.

Coverage includes exact canonical tracked/index/third-parent OIDs, cleanup variants and source timing, literals/nested attributes, canonical-empty no-op, safecrlf refusal/warnings/callback failures, callback raw/index mutation, staged deletion guards, per-file and aggregate expansion before publication, apply/pop/index restoration, planned/deleted attributes, unchanged canonical replay paths, third-parent phase separation/collisions, binary/symlink bytes, and raw EOL-only races during save/apply.

Late BOM probe confirmed existing source policy: when untracked third-parent `.gitattributes` begins with UTF-8 BOM followed by `*.txt text eol=crlf`, pinned Git stash apply restores canonical LF `u.txt` as LF, preserves the BOM bytes, and leaves tracked output LF. Current blob projection matches; a native-versus-pinned-Git regression covers both formats. No production BOM policy change was needed.

No known unresolved task issue. Native canonical no-op and all-untracked-destination collision refusal intentionally preserve the frozen native contract, including its existing bounded differences from Git's occasional raw-stat empty stash and partial untracked checkout behavior.

## Checkpoint addendum (supersedes initial completion status)

Review found warning-callback attribute-source inconsistency. Regression red run: 6 examples, 4 failures, 0 errors. Proposed stash-only fix and tests committed as eb47d749b90aa51f614beee03f36ef8f21726f6e. No successful green run or scoped fix review has completed; validation remains paused by user after process exhaustion.

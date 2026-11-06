# Task 1 — shared EOL workflow foundation

Read design.md Shared interfaces and Binding contract; this brief is your exact task requirements. User authorized implementation of merge/replay/stash in parallel after shared contract. Base 1ff359874fc931f33d53aa5fb22fc4913e1fa62b. Work only in /workspace/work/git-eol-workflows/foundation on feature/eol-workflow-foundation.

Own only src/git/conversion/workflows.cr (new), src/git/conversion.cr and src/git/conversion/attributes.cr (new source-policy option), src/git.cr (one require), src/git/merge/three_way/recovery.cr (encode raw outputs), src/git/workflow/hard_reset.cr (conversion-aware clean_only for fast-forward), spec/eol_workflow_support_spec.cr (new). Parent owns docs/integration and all other source ownership is reserved. No subagents or pushes. Commit task-owned changes once verified; report full commit range in task-1-report.md beside this brief.

## Exact interfaces to implement

- Conversion.for_index(repository : Repository, current : Array(Index::Entry), *, edits : Array(Index::Edit) = [] of Index::Edit, writes : Array(Checkout::Write) = [] of Checkout::Write, config : Config? = nil, max_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608, check : Proc(Nil)? = nil) : Conversion.
  Complete planned attribute map: select index stage0 else stage2 (nonregular is nil), overlay Put/Remove/PutStages edits, then actual canonical attribute write.data at final relocated paths. Preserve explicit deletions. Conflicted marker writes may not exist in object DB: store their bytes via bounded write_blob for attribute parsing, never assume write.oid identifies marker bytes. No index/ref/worktree mutation; ordinary loose objects permitted. InvalidateStat does not change source. Extend Conversion/Attributes constructors with `worktree_fallback : Bool = false` for blob-map sources. True without attribute_blobs is invalid. In rules_for: present map key (including nil) is authoritative; only an ABSENT key may read current worktree attrs when fallback true. No further index fallback because map already projects index. for_index sets fallback true (Git checkout index-first). Existing map/tree defaults remain exact and unchanged. Forward config/index/byte/check bounds.
- Conversion#materialize(writes : Array(Checkout::Write), *, max_total_bytes : Int64, operation : String = "Git checkout") : Array(Checkout::Write). Copy writes; convert regular data, retain canonical oid/path/mode, symlinks raw. Enforce each file max_bytes and aggregate materialized output bound BEFORE publication, cancellation. Validate supported modes/path. Never mutate original array/record data.
- Conversion#raw_states(states : Hash(String, Checkout::FileState), *, max_total_bytes : Int64, operation : String = "Git checkout") : Hash(String, Checkout::FileState). Load canonical blobs boundedly; materialize regular data, symlinks raw, return raw output digest. Bound aggregate reads AND outputs, cancellation, no source map mutation or index/ref/worktree publication.
- Add root require after index/merge plan definitions so `require "git"` has helpers.

## Receipt correction

Recovery.encode keeps current format/legacy decode behavior and operation/byte/entry checks. Validate each write.oid using ObjectId.valid! before deriving receipt output digest from ACTUAL write.data. Do not reinterpret existing raw receipt data through conversion. Existing old receipts remain valid because old data == old canonical blob bytes.

## Fast-forward shared path

In reset_head_hard, clean_only true needs source Conversion (current attrs, same resolved config) and conversion-aware require_clean!; keep raw observations/current bytes for guards. Target Conversion is used for all modes (not only !clean_only). Compare canonical clean_current to old tree for clean-only admission. For clean_only skip canonical-unchanged index/target entries regardless stale stat (FF must not rewrite attrs-only unchanged files); ordinary public hard reset retains its existing stat-dirty rematerialization behavior. Don't load dirty source attrs in ordinary !clean_only reset. Preserve stats/cache and logical result semantics.

## Required tests / verification

Write failing regressions first: helper planned attrs with conflict marker data and deletion/ours fallback, final relocated rule matching, canonical write IDs retained vs raw output states, symlink raw, aggregate/per-file expansion failure, cancellation, receipt canonical-vs-raw hash and invalid canonical ID rejection, clean-only FF accepting clean CRLF while overwriting through raw guards and leaving unchanged canonical paths alone.
Run focused support + existing eol conversion/checkout/hard_reset/merge_fast_forward/recovery metadata tests on Crystal1.22.2 and1.13.0. Assert oracle exactly `/workspace/toolchains/git-2.47.3/bin/git --version` -> `git version 2.47.3`. Source /workspace/toolchains/env.sh; distinct CRYSTAL_CACHE_DIR=/workspace/work/git-eol-workflows/cache-foundation. Full suites are parent integration gate, don't duplicate broad runs unnecessarily. Format both compiler lanes and git diff --check.

Report status DONE / DONE_WITH_CONCERNS / BLOCKED, files/commits, red/green evidence, exact commands/counts/log paths and any boundary concerns. Raise shared-contract issues promptly. Do not silently weaken test expectations or edit another stream's files.

## Approved follow-up source-policy extension

Add optional worktree_index_fallback : Bool = false to Conversion and Attributes. Only valid with a blob map and worktree_fallback:true. For ABSENT map keys, read secure worktree file; if absent and extra flag true, use existing index_blobs fallback. A PRESENT nil key blocks both. for_index keeps extra flag false, preserving projected context and no new index reads. This permits selected stash keep_index to override selected attrs with index blobs while unselected attrs retain WT-first/index fallback, without unsafe ad hoc readers. Add the requested policy regression cases, both focused lanes, follow-up commit and report addendum.

# git

A native Crystal Git library for SHA-1 and SHA-256 repositories.
It reads and writes repositories without a Git subprocess, a shell or libgit2,
and has no dependency on a host application or permission model. It requires
Crystal >= 1.13.0 and the standard library's `Compress::Zlib` (which calls
native zlib).

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  git:
    github: immateria/Git.cr
```

Then install it:

```sh
shards install
```

```crystal
require "git"

repository = Git::Repository.new("/path/to/repository")
branch, head_oid = repository.head
```

The trusted caller handles permission checks, operation limits, authorization,
secret masking, cancellation and any operating-system confinement. This library
enforces bounded parsing and reports unsupported Git formats rather than
approximating them. An optional adapter outside this shard uses it for read-only
agent tools and controls every grant; see
[docs/CAPABILITY_BOUNDARY.md](docs/CAPABILITY_BOUNDARY.md) for the boundary.

## What it does

- **Repository selection.** `Repository.new` follows valid `.git` pointer files
  (linked worktrees, separate Git directories) and opens bare repositories;
  `follow_gitfile: false` requires an explicitly host-selected
  `linked_worktree_admin_dir:`. `discover: true` searches ancestors, bounded by
  `discovery_ceiling:`. It does not read the process environment:
  `Repository.from_environment(cwd, variables)` takes `GIT_DIR`, `GIT_COMMON_DIR`
  and `GIT_WORK_TREE` from a hash the caller supplies. Ownership and bare-repository
  admission checks are available (`open_with_ownership_check`,
  `open_with_bare_repository_check`).
- **Reading.** Loose and packed objects (including REF_DELTA), refs and
  packed refs, the HEAD tree, index versions 2 to 4, bounded working-tree status
  and per-file diffs, and effective configuration with provenance. Paths are
  byte-exact (`Git::PathBytes`), including invalid UTF-8 on Linux; callers must not
  normalize them for lookup or permission decisions. `Git::RefName.valid?` follows
  the byte-level `git check-ref-format` grammar. `Git::TextDiff` emits Git's
  C-style quoted path headers and accepts only UTF-8 text. `Git::Ignore` evaluates
  repository `.gitignore`, nested `.gitignore` and `info/exclude`, parent before
  child, so an ignored parent cannot be re-included by negating a child.
- **Writing objects.** `init` makes a repository and probes its file system as
  Git's init does, writing `filemode`, `symlinks`, `ignorecase` and, on macOS,
  `precomposeunicode` as Git would. `write_blob`, `write_tree`, `write_commit` and
  `write_tag` publish loose objects, and `create_branch` and `create_tag` create
  refs. `Config::FileEditor` makes explicit file-scoped configuration edits with an
  exclusive `.lock` and atomic replace.
- **Index and refs.** `stage_blob`, `stage_file`, `remove_from_index`,
  `write_index_tree` and `commit_staged` stage and commit with index versions 2 to
  4. `update_ref`, `update_refs`, `change_refs` and `delete_ref` do single-ref
  compare-and-swap updates and mixed create/update/delete batches, with packed-refs
  rewriting, optional reflog appends and explicit partial-publication diagnostics.
- **Recovery.** `change_refs_recoverably`, `change_index_and_refs_recoverably`
  and `commit_index_changes_recoverably` write a bounded redo journal and a
  checksummed finalization receipt; `recover_refs`, `recover_index_and_refs`,
  `pending_ref_finalizations` and `finish_ref_finalization` finish or clean up an
  interrupted run. Durable transactions share a per-common-directory advisory lock
  and refuse to start while a journal is pending. This is a recoverable intent
  record, not global crash atomicity or rollback.
- **Workflows.** `checkout_branch`, `restore_paths`, `reset_head`,
  `reset_head_hard`, `merge_fast_forward`, `merge_three_way` (with
  `merge_continue`, `merge_abort` and `merge_conflicts`), the single-commit
  sequencer (`cherry_pick`, `revert`), linear `rebase` (with `rebase_continue`,
  `rebase_skip` and `rebase_abort`) and `stash_push`, `stash_list`, `stash_apply`,
  `stash_pop` and `stash_drop`. `stash_push` takes `include_untracked`,
  `include_ignored`, `keep_index`, `staged_only` and literal repository-relative
  `paths:`; there are no globs or pathspec magic. Merge and replay conflicts keep
  Git-compatible index stages and worktree leaves, and rebase keeps commits that
  were empty in their source history unless the caller says otherwise. Repeated-line
  alignment and Git's full `ort` conflict layout are intentionally bounded.

Worktree, index and HEAD are published separately. `Checkout::PartialPublication`
and related types report possibly incomplete results; they do not promise rollback.
Pinned directory descriptors (`src/git/descriptor_path.cr`, with
`renameat2(RENAME_NOREPLACE)` on Linux and `renameatx_np(RENAME_EXCL)` on macOS)
handle index publication, single-ref updates, mixed refs, redo journals and receipts.
They do not provide atomic conditional replacement of existing tracked files.
The library runs on Linux and macOS; Windows is unverified.

## Checks

`crystal spec` runs the specs. The specs that compare against upstream Git need
**Git 2.47.3**, selected by `GIT_ORACLE_BINARY` (default: `git` on `PATH`); the
oracle refuses any other version. Runtime Git operations never launch that binary.
[docs/ORACLE_FIXTURES.md](docs/ORACLE_FIXTURES.md) lists the fixtures and their
profiles. In an umbrella workspace that vendors this shard,
`scripts/test-all git-differential` runs a bounded routine oracle suite.

## Current limits

- Not implemented: clone, fetch, pull, push and remote handling; worktree and
  submodule lifecycle; hooks, filters and signing; and full attribute and ignore
  parity (global excludes, case folding and the whole of Git's wildmatch). Reftable
  ref storage, split and sparse indexes, replace refs, grafts and alternate object
  directories are unsupported.
- Text diffs and merges use bounded algorithms and handle UTF-8 text only, not
  binary or very large patches. `0b` and `0B` configuration integer prefixes follow
  a fixed binary-integer policy independent of the host libc.
- Working-file status and diffs use a bounded regular-file reader and an ancestor
  symlink check. They reject observed redirection and concurrent change but are not
  kernel-atomic against hostile replacement.

## Verification history

The recorded oracle runs used Git 2.47.3, Crystal 1.21.0 and Linux x86-64 in a
ChatGPT Linux sandbox. On 2026-11-02 all 640 examples passed with Crystal 1.22.2
and Git 2.47.3 built from source, as a normal user, on macOS 15.4.1 arm64 and
Linux 7.0 arm64. On 2026-11-03 all 640 examples passed with Crystal 1.13.0 and
the same oracle Git on macOS 15.4.1 arm64. That sets the `crystal:` floor:
1.12.0 and earlier put `system_fsync` on the File layer, where a bare
`IO::FileDescriptor` has no `fsync`.

Apple's file systems refuse names that are not UTF-8. On those systems the
specs put such names into the index and packed-refs without a file, as Git
would write them, and skip the work-tree and loose-ref checks that need one
(`GitOracle::RAW_NAMES`). The init probes were compared with Git's on FAT,
exFAT and case-sensitive APFS on macOS and on vfat on Linux, by hand, not in a
spec. Older and newer Git versions and Windows are unverified.

## Further reading

Design notes: [docs/CAPABILITY_BOUNDARY.md](docs/CAPABILITY_BOUNDARY.md) (what
belongs in the library and what in an adapter) and
[docs/SEMANTIC_NAMESPACES.md](docs/SEMANTIC_NAMESPACES.md) (why the types are named
as they are). The capability matrix and per-gap status are
[docs/CORE_FUNCTION_COVERAGE.md](docs/CORE_FUNCTION_COVERAGE.md) and
[docs/PARITY_LEDGER.md](docs/PARITY_LEDGER.md).

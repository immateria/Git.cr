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
repository.head.symref_target                # => "refs/heads/main"
repository.rev_parse("main~2:src/app.cr")    # => blob ID
repository.log(["origin/main..HEAD"], limit: 20).commits.each { |commit| puts commit.subject }

me = Git::Signature.new("Me", "me@example.com", Time.utc.to_unix, 0)
repository.switch("feature", create: true, from: "main", actor: me) # git switch -c
repository.stage                                # git add -A
print repository.diff(cached: true)             # git diff --cached
repository.commit(author: me, committer: me, message: "Fix the app")
repository.amend(committer: me, message: "Fix the app properly")
repository.stash.push(actor: me) # nil when there is nothing to stash
```

`Repository` keeps Git's top-level commands as verbs (`commit`, `switch`,
`reset`, `restore`, `merge`, `rebase`, `cherry_pick`, `fetch`, `push`, ...).
Families of subcommands hang off handles named for what they manage:
`refs`, `branches`, `tags`, `remotes`, `stash` and `recovery`. Without
arguments, `merge`, `rebase`, `cherry_pick`, `revert` and `sequencer` give the
operation in progress (`repository.merge.abort`,
`repository.rebase.continue(committer: me)`).

Remote work goes through an explicit transport:

```crystal
tls = OpenSSL::SSL::Context::Client.new
credentials = ->(url : String, attempt : Int32) do
  attempt == 1 ? Git::Transport::Credential.new("me", ENV["TOKEN"]) : nil
end
transport = Git::Transport::HTTP.new("https://example.com/project.git",
  credentials: credentials, tls: tls)
repository = Git::Repository.clone(transport, "/tmp/project",
  url: "https://example.com/project.git")
repository.fetch("origin", transport: transport)
repository.push("origin", ["main"], transport: transport)
repository.push("origin", ["main"], transport: transport,
  lease: Git::Push::Lease.tracking) # --force-with-lease
repository.fetch(transport, ["+refs/heads/*:refs/remotes/mirror/*"]) # no configured remote
```

Local paths (`Git::Transport::Local`, served in-process) and plain HTTP(S)
URLs without credentials can be given as strings. ssh, git:// and other
programs need `Git::Transport::SSH`, `Git::Transport::Daemon` or
`Git::Transport::Command`, constructed with the program and environment the
caller chooses.

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
- **Reading.** Loose and packed objects (`read_object`, `object_header`,
  `read_commit`, typed by `Git::ObjectType`), refs and packed refs, the HEAD
  tree (`head_entry`, `head_directory`, `read_head_file`), index versions 2 to
  4, bounded status (`staged_changes`, `working_changes`) and per-file
  comparisons (`staged_file`, `working_file`), and effective configuration with
  provenance. Paths are
  byte-exact (`Git::PathBytes`), including invalid UTF-8 on Linux; callers must not
  normalize them for lookup or permission decisions. `Git::RefName.valid?` follows
  the byte-level `git check-ref-format` grammar. `Git::Ignore` evaluates
  repository `.gitignore`, nested `.gitignore` and `info/exclude`, parent before
  child, so an ignored parent cannot be re-included by negating a child.
- **Writing objects.** `init` makes a repository and probes its file system as
  Git's init does, writing `filemode`, `symlinks`, `ignorecase` and, on macOS,
  `precomposeunicode` as Git would. `write_blob`, `write_tree`, `write_commit` and
  `write_tag` publish loose objects, and `branches.create` and `tags.create`
  create refs. `Config::FileEditor` makes explicit file-scoped configuration edits with an
  exclusive `.lock` and atomic replace.
- **Index and refs.** `stage` is `git add -A` (or `-u` with `tracked_only:`)
  over the whole tree, files or directories, in one index write; `remove` is
  `git rm` with Git's safety checks (`cached:`, `force:`, `recursive:`).
  `stage_blob`, `stage_file`, `remove_from_index`, `write_index_tree`, `commit`
  and `amend` (`git commit --amend`) stage and commit with index versions 2 to
  4. `refs.update` and `refs.delete` are single-ref compare-and-swap updates and
  `refs.apply` takes a mixed create/update/delete batch, with packed-refs
  rewriting, optional reflog appends and explicit partial-publication
  diagnostics. `refs.list`, `refs.resolve?`, `refs.set_symbolic`,
  `refs.detach_head` and `refs.pack` cover the rest of `for-each-ref`,
  `symbolic-ref`, `update-ref` and `pack-refs`.
- **Recovery.** `recovery.apply` (refs, or index edits and refs together) and
  `recovery.commit` write a bounded redo journal and a checksummed finalization
  receipt; `recovery.resume`, `recovery.pending`,
  `recovery.pending_finalizations` and `recovery.finish_finalization` finish or
  clean up an interrupted run. Durable transactions share a per-common-directory advisory lock
  and refuse to start while a journal is pending. This is a recoverable intent
  record, not global crash atomicity or rollback.
- **Workflows.** `switch` (to a branch; `create:` and `from:` as `-c`;
  `detach:`; and Git's guess of a remote branch, with an upstream set as
  `branch.autoSetupMerge` says), `restore`, `restore_staged`, `read_tree`, `reset`
  (soft, mixed or hard), `fast_forward`, `merge` (then `merge.continue`,
  `merge.abort` and `merge.conflicts`), the single-commit sequencer
  (`cherry_pick` and `revert`, then `cherry_pick.continue` and so on), linear
  `rebase` (then `rebase.continue`, `rebase.skip` and `rebase.abort`) and
  `stash.push`, `stash.list`, `stash.show`, `stash.apply`, `stash.pop` and
  `stash.drop`. `stash.push` takes `include_untracked`,
  `include_ignored`, `keep_index`, `staged_only` and literal repository-relative
  `paths:`; there are no globs or pathspec magic. Merge and replay conflicts keep
  Git-compatible index stages and worktree leaves, and rebase keeps commits that
  were empty in their source history unless the caller says otherwise. Repeated-line
  alignment and Git's full `ort` conflict layout are intentionally bounded.
  Given an `actor:` (or, for `merge` and `pull`, the committer), `switch`,
  `reset`, `fast_forward`, `merge`, `pull` and `branches.create` write Git's
  reflog lines, and `reset`, `merge`, `fast_forward`, `pull` and `rebase`
  record `ORIG_HEAD`. Commands that take a commit accept the `rev_parse`
  grammar.

- **History.** `rev_parse` resolves Git's everyday revision grammar: full
  and abbreviated IDs, ref lookup rules, `@`, `@{n}`, `@{upstream}`, `~`,
  `^`, `^{type}`, `<rev>:<path>` and `:<path>`. `rev_list` and `log` take
  `^A`, `A..B` and `A...B`, and `log` orders by date or topologically
  (`History::Order`); `ahead_behind`, `merge_bases` and `ancestor?` answer
  ancestry questions; `reachable_objects` is `rev-list --objects`. `diff_trees` and `commit_changes` list added,
  deleted, modified, type-changed and (exactly) renamed paths between trees as
  `TreeDiff::Change` values, as `git diff-tree -r` does.
- **Diffs.** `diff` mirrors `git diff`'s forms (index against worktree,
  `cached:` for HEAD or a revision against the index, a revision against the
  worktree, two trees) and `commit_patch` is a commit against its first parent.
  Both return a `Git::Patch`, per-file sections whose text is byte for byte
  `git diff --no-color`: xdiff's Myers diff with its heuristics and the indent
  heuristic, function-name hunk headers, exact renames, mode and type changes,
  binary files, symlinks, gitlinks and C-style quoted paths.
- **Branches and tags.** `branches.list` (`Git::Branch`, with upstream and
  ahead/behind), `branches.create`, `branches.delete`, `branches.rename`,
  `branches.upstream` and `branches.set_upstream`; `tags.list`, `tags.create`
  and `tags.delete`.
- **Packs.** Pack reads cache verified indexes and follow delta chains of any
  Git depth. `Pack::Writer`, `Pack::Delta` and `Pack::Builder` (pack-objects,
  with delta search and reuse of stored deltas) write packs; `Pack::Indexer`
  and `Repository#index_pack` are index-pack, including thin-pack completion,
  and write `.idx` and `.rev` files (`Pack::IndexFile`, `Pack::ReverseIndexFile`)
  byte-identical to Git's.
- **Remotes.** `remotes.add`, `remotes.remove`, `remotes.rename`,
  `remotes.set_url` and `Remote::Refspec`;
  `clone`, `fetch` (from a remote name or a `Transport`; tag following, prune,
  shallow `depth:`, FETCH_HEAD),
  `pull` (fast-forward or merge), `push` (fast-forward rules, force,
  `lease:` for `--force-with-lease`, atomic, deletes) and `ls_remote`, reporting `Fetch::Result`, `Pull::Result` and
  `Push::Result`. Fetch speaks protocol v2 (`Protocol::UploadPack::Client`);
  push speaks receive-pack v0/v1 (`Protocol::ReceivePack::Client`), and both
  services have native servers. Every `Git::Transport` is one of `Local`
  (in-process), `HTTP` (smart HTTP with a credential callback, TLS context and
  CONNECT proxy), `SSH`, `Daemon` (git://) and `Command`.
  `require "git/server/http_handler"` adds an `HTTP::Handler` that serves
  repositories to Git clients over smart HTTP.
- **Maintenance.** `repack` (one pack of everything reachable, honouring
  `.keep`), `prune_packed`, `refs.pack`, `gc` and `fsck` (corrupt, missing and
  unreachable objects), reporting `Repack::Result`, `Gc::Result` and
  `Fsck::Report`.

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
The remote specs also run `git http-backend`, `git daemon`, `git upload-pack` and
`git receive-pack` from that installation on loopback addresses.
[docs/ORACLE_FIXTURES.md](docs/ORACLE_FIXTURES.md) lists the fixtures and their
profiles. In an umbrella workspace that vendors this shard,
`scripts/test-all git-differential` runs a bounded routine oracle suite.

`bench/realworld.cr` checks the library against Git on a clone of any real
repository and times both; [docs/REAL_WORLD.md](docs/REAL_WORLD.md) has the
results for three public repositories and what they found.

## Current limits

- Not implemented: worktree and submodule lifecycle; hooks, filters and
  signing; credential helpers; protocol v0/v1 fetch (servers must speak
  protocol v2 for fetching, as Git servers have by default since 2.26),
  partial clones, `rebase` pulls, similarity-based rename detection and copies,
  globs and pathspec magic; and full
  attribute and ignore parity (global excludes, case folding and the whole of
  Git's wildmatch: Git's `?` and `[...]` match single bytes, the library's
  whole characters). Reftable ref storage, split and sparse indexes, replace
  refs, grafts and alternate object directories are unsupported.
- Clone's checkout writes the tree into an empty worktree; it does not apply
  filters or attributes. Indexes the library writes (clone, checkout,
  `stage`) carry no stat data, so the next `status`, Git's or the library's,
  hashes every file; status trusts the stat data in indexes Git wrote.
- Merges use a bounded text algorithm and handle UTF-8 text only. Diffs take
  any bytes, but apply no attributes or textconv; hunk headers use Git's
  default function-name rule, not the language drivers `.gitattributes` can
  select (`*.c diff=cpp`), and IDs are abbreviated to at least 7 digits
  rather than scaling with the object count (`abbrev:`).
- A detached HEAD can be reached with `switch(detach: true)` and left with
  `switch`, but `commit`, `amend`, `reset` and `merge` need a checked-out branch.
- `0b` and `0B` configuration integer prefixes follow a fixed binary-integer
  policy independent of the host libc.
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

On 2026-11-03 all 681 examples passed with Crystal 1.13.3, 1.21.1 and 1.22.2
and Git 2.47.3 built from source on Linux x86-64 (Ubuntu 24.04), including the
pack, remote, transport, porcelain and maintenance specs. Crystal 1.13 resolves
the oracle's `git` through the restricted `PATH` it is given, so set
`GIT_ORACLE_BINARY` to the 2.47.3 binary's full path there. A native clone of
`github.com/crystal-lang/crystal` (depth 1, 2,749 files) through an HTTPS
CONNECT proxy passed `git fsck` and left a clean `git status`.

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

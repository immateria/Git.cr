# Git.cr

A native Crystal Git implementation for SHA-1 and SHA-256 repositories.
Read and write objects, refs and indexes; stage and commit files; merge and
rebase history; and clone, fetch and push repositories.

Repository operations and the local, HTTP(S) and `git://` transports run
natively, with no Git executable or libgit2 dependency. SSH and command
transports can launch programs explicitly selected by the caller.

Requires **Crystal >= 1.13.0**. There are no external shard dependencies;
compression uses the standard library's zlib bindings, and HTTPS uses OpenSSL.

## Installation

Add to your `shard.yml`:

```yaml
dependencies:
  git:
    github: immateria/Git.cr
```

Then run:

```sh
shards install
```

## First commit

This creates a new repository on `main`, stages a file and commits it:

```crystal
require "git"

path = "demo"
Dir.mkdir_p(path)
repository = Git::Repository.init(path)
me = Git::Signature.new("Me", "me@example.com", Time.utc.to_unix, 0)

File.write(File.join(path, "hello.txt"), "Hello from Crystal\n")
repository.stage(["hello.txt"], config: repository.config)
oid = repository.commit(author: me, committer: me, message: "Initial commit\n")

puts oid
```

`init` takes an existing directory and refuses existing repository metadata.
For SHA-256, pass `object_format: Git::ObjectId::Format::SHA256`.
Identities are explicit; `Git::Signature` takes a name, email, Unix timestamp
and UTC offset in minutes.

## Read a repository

```crystal
require "git"

repository = Git::Repository.new("demo")
puts repository.rev_parse("HEAD:hello.txt") # Blob ID
puts repository.read_head_file("hello.txt")

repository.log(["HEAD"], limit: 10).commits.each do |commit|
  puts commit.subject
end

print repository.diff               # Index against working files
print repository.diff(cached: true) # HEAD against the index
```

`Repository.new` opens worktrees and bare repositories, and follows valid
`.git` pointer files for linked worktrees or separate Git directories.
Use `discover: true` to search ancestors and `discovery_ceiling:` to bound
that search. `follow_gitfile: false` requires an explicitly selected
`linked_worktree_admin_dir:` when opening through a pointer file.

Revision arguments use Git's familiar grammar: abbreviated IDs, `HEAD~2`,
`main^`, `@{upstream}`, reflog selectors, `main:path/to/file`, and ranges
such as `main..topic` or `main...topic` where the operation accepts ranges.

## Line blame

Blame a committed file at HEAD or an explicit revision:

```crystal
blame = repository.blame("hello.txt", revision: "HEAD")
blame.each do |line|
  print "#{line.final_line} #{line.author.name} #{line.commit_oid[0, 8]} "
  print line.content
end
```

Each line also exposes its `original_path`, one-based `original_line`,
separate `committer` signature and `boundary?` flag. Content retains its LF
when present and preserves binary and invalid UTF-8 bytes. Blame reads objects,
so staged changes and working files do not affect it; bare repositories work too.

The default follows all parents and exact/edited whole-file renames. Use
`first_parent: true` for first-parent attribution or `follow_renames: false`
to keep the same path. `max_history_nodes`, `max_object_bytes`,
`max_total_bytes`, `max_entries`, `max_lines`, `max_diff_work` and `check:`
bound the query. The byte and line budgets include cached historical objects
and distinct parsed blobs, not just the requested file.

Working-tree/reverse blame, line-range selection, moved/copied-line tracking,
ignored revisions and whitespace-ignore options are not implemented. Identities
come from commit headers; blame-specific repository configuration, mailmap
aliases and textconv filters are not applied.

## Workflows and conflicts

Top-level operations are verbs: `stage`, `commit`, `amend`, `switch`, `reset`,
`restore`, `merge`, `cherry_pick`, `revert`, `rebase`, `fetch` and `push`.
Related operations live on handles: `branches`, `tags`, `refs`, `remotes`,
`stash` and `recovery`.

For example, after the first commit above:

```crystal
repository.switch("feature", create: true, from: "main", actor: me)
File.write(File.join(repository.root, "hello.txt"), "Hello from a branch\n")

repository.stage(["hello.txt"], config: repository.config)
repository.commit(author: me, committer: me, message: "Update greeting\n")

repository.switch("main", actor: me)
result = repository.merge("feature", author: me, committer: me,
  message: "Merge feature\n")

unless result.conflicts.empty?
  puts "Resolve these paths: #{result.conflicts.join(", ")}"
end
```

A fast-forward advances the branch. A clean divergent merge creates a
two-parent commit. Conflicts return paths in `result.conflicts` and leave
the operation in progress, with real base/ours/theirs index stages.

If the merge reports conflicts, edit those files, then stage the resolutions
and continue:

```crystal
unless result.conflicts.empty?
  repository.stage(result.conflicts, config: repository.config)
  repository.merge.continue(author: me, committer: me)
end
```

Alternatively, `repository.merge.abort` restores the original index and
merge-touched worktree content, including indexed conflict resolutions.
Merge requires a common ancestor, a clean index and clean tracked files;
it currently refuses linked worktrees.

Calling `merge`, `cherry_pick`, `revert`, `rebase` or `sequencer` without
arguments returns an operation handle. Use `state?` or `in_progress?` to
inspect it. The same pattern supports `repository.cherry_pick.abort`,
`repository.rebase.skip(committer: me)` and
`repository.rebase.continue(committer: me)`.

## Remotes and transports

Local paths and public HTTP(S) URLs can be passed directly:

```crystal
require "git"

repository = Git::Repository.clone("https://github.com/immateria/Git.cr.git", "git-cr")
repository.fetch("origin")
```

For authentication, custom TLS settings or an HTTP CONNECT proxy, construct
the transport explicitly. Use a remote you can write to for `push`:

```crystal
credentials = ->(_url : String, attempt : Int32) do
  attempt == 1 ? Git::Transport::Credential.new("username", ENV["GIT_TOKEN"]) : nil
end

transport = Git::Transport::HTTP.new("https://example.com/project.git",
  credentials: credentials, tls: OpenSSL::SSL::Context::Client.new)

repository = Git::Repository.clone(transport, "project",
  url: "https://example.com/project.git")
repository.fetch("origin", transport: transport)
repository.push("origin", ["main"], transport: transport)
repository.push("origin", ["main"], transport: transport,
  lease: Git::Push::Lease.tracking) # --force-with-lease
```

| Transport | Connection | External program |
| --- | --- | --- |
| `Git::Transport::Local` | Repository served in process | None |
| `Git::Transport::HTTP` | Smart HTTP(S), with optional credentials, TLS context and CONNECT proxy | None |
| `Git::Transport::Daemon` | `git://` over TCP | None |
| `Git::Transport::SSH` | SSH or scp-style URL | Caller-selected SSH command |
| `Git::Transport::Command` | Git service over stdin/stdout | Caller-selected command and environment |

Supply a transport explicitly for `git://`, SSH and custom commands. For
example, `Git::Transport::Daemon.new("git://example.com/project.git")` uses
native TCP. `Git::Transport::SSH.new(url, ssh_command: ["/usr/bin/ssh"])`
selects an SSH program. HTTP credentials, proxies and command environments
are explicit; the library does not consult ambient credential helpers.

Fetch uses protocol v2; push uses receive-pack v0/v1. Both services have
native servers. `require "git/server/http_handler"` adds
`Git::Server::HTTPHandler` for serving repositories to Git clients over
smart HTTP; the caller supplies repository selection and authorization.

## API at a glance

| Area | Capabilities and entry points |
| --- | --- |
| Objects | SHA-1/SHA-256; loose and packed objects; `read_object`, `object_header`, `read_commit`, `write_blob`, `write_tree`, `write_commit`, `write_tag` |
| Index and worktree | Index v2–v4; `stage`, `stage_blob`, `stage_file`, `remove`, `write_index_tree`, `staged_changes`, `working_changes`, `staged_file`, `working_file` |
| History | `rev_parse`, `rev_list`, `log`, `blame`, `ahead_behind`, `merge_bases`, `ancestor?`, `reachable_objects` |
| Diffs | `diff`, `commit_patch`, `diff_trees`, `commit_changes`; text/binary, mode/type changes, exact renames, attributes and function-name hunk headers |
| Branches and tags | Create, list, copy, rename and delete branches; upstreams and filters; lightweight and annotated tags |
| Local workflows | `init`, `commit`, `amend`, `switch`, `restore`, `restore_staged`, `read_tree`, `reset`, `fast_forward`, `merge`, `cherry_pick`, `revert`, linear `rebase` |
| Stashes | `stash.push`, `list`, `show`, `apply`, `pop`, `drop`; untracked/ignored files, `keep_index`, `staged_only`, literal `paths:` |
| References and recovery | Compare-and-swap updates, mixed ref batches, packed refs, reflogs, redo journals and finalization receipts |
| Remotes | `remotes`, `clone`, `fetch`, `pull`, `push`, `ls_remote`; shallow fetch, pruning, tag following, force-with-lease and atomic push |
| Packs and maintenance | Pack/delta readers and writers, thin-pack completion, `.idx`/`.rev` files; `index_pack`, `repack`, `prune_packed`, `gc`, `fsck` |
| Configuration and ignores | Configuration with provenance; `Git::Config::FileEditor`; root/nested `.gitignore`, `info/exclude`, and explicit `core.excludesFile` |

`stage` covers additions, modifications and deletions, like `git add -A`;
use `tracked_only: true` for `git add -u`. Pass `config: repository.config`
where offered to apply supported configuration, including `core.filemode`
and an explicit `core.excludesFile`. Environment-derived repository selection
is also opt-in: `Repository.from_environment(cwd, variables)` takes a
caller-supplied hash.

The merge engine detects exact and edited regular-file renames at 50% span
similarity, combines independent edits, preserves divergent rename stages
and relocates file/directory conflicts. Multiple common ancestors are merged
recursively into virtual bases. Rename/add conflicts preserve intermediate
source blobs, including nested text markers and context-specific binary
selection.

For per-operation coverage and remaining gaps, see the
[capability matrix](docs/CORE_FUNCTION_COVERAGE.md) and
[parity ledger](docs/PARITY_LEDGER.md).

## Limits and recovery

Operations expose byte, entry and history limits, with `check:` callbacks
where supported for cancellation. Paths are byte-exact, including invalid
UTF-8 where the filesystem permits it. Preserve those bytes for lookup and
authorization decisions.

Worktree, index and HEAD publication are separate steps. A
`Checkout::PartialPublication` or related error reports an incomplete
operation; it does not promise rollback. Merge and replay save versioned
worktree-output receipts before publication so abort can recognize writes
made before the index was published. Receipts bind the original/source
commits and are checked during publication and abort. Merge continuation
also validates its receipt before committing.
Changed or ambiguous unindexed files are preserved and cause recovery to
refuse. Legacy path-only receipts support indexed recovery but cannot
authorize removal of an unindexed file. Durable `recovery` transactions
provide redo and finalization, rather than global crash atomicity.

The caller supplies identities, credentials, authorization, cancellation
policy and any operating-system confinement. Filesystem checks reject
observed redirection and concurrent changes; they do not provide atomic
conditional replacement against hostile writers. See the
[capability boundary](docs/CAPABILITY_BOUNDARY.md) for integration details.

Current compatibility limits include:

- **Merge behavior.** Automatic content merging handles UTF-8 text; rename
  scoring also accepts binary data. Rename search permits at most 1,000,000
  inexact comparisons and `max_total_bytes` of distinct candidate blobs per
  tree merge. Recursive synthesis has a depth limit of 64 and a fold-work
  limit of `max_history_nodes`. Full `ort` hunk alignment, candidate selection,
  attributes, copy detection and directory renames remain incomplete.
  Rename/add collisions with differing source kinds and virtual-base
  file/directory conflicts are rejected.
- **Repository formats.** Reftable refs, split/sparse indexes, replace refs,
  grafts and alternate object directories are unsupported.
- **Git integrations.** Worktree/submodule lifecycle, hooks, clean/smudge
  filters, signing, credential helpers and partial clones are not implemented.
- **Selection and configuration.** Paths are literal files or directories;
  glob/pathspec magic and full attribute/ignore parity are unsupported.
  Explicit `core.excludesFile` works through supplied configuration; ambient
  global excludes, case folding and the full wildmatch grammar are not applied.
- **History and transport.** Rebase is linear; `pull` supports fast-forward
  or merge, not rebase. Fetch requires a protocol v2 server. Diff rename
  detection is exact-content only, separate from merge similarity detection.

## Development and verification

The differential specs require **Git 2.47.3** and reject other versions.
Use an absolute path when that version is not the default Git installation:

```sh
crystal tool format --check
GIT_ORACLE_BINARY=/absolute/path/to/git-2.47.3/bin/git crystal spec
```

Git is an oracle for these tests, not a requirement for native repository
operations. Remote specs also run `git http-backend`, `git daemon`,
`git upload-pack` and `git receive-pack` on loopback addresses.

The latest full verification, on **2026-11-06**, passed **1,174 examples** on
Crystal **1.13.0** and **1.22.2**, with Git **2.47.3**, on Linux x86-64.
Earlier runs covered macOS 15.4.1 arm64 and Linux 7.0 arm64 with 640 examples
(2026-11-02/03), and Linux x86-64 with 681 examples on Crystal 1.13.3, 1.21.1
and 1.22.2 (2026-11-03). The current suite has not been rerun on macOS;
Windows is unverified.

Crystal 1.13.0 is the minimum because it provides `fsync` on
`IO::FileDescriptor`. Filesystem tests account for platforms that refuse
non-UTF-8 names. Init probes were also compared manually with Git on FAT,
exFAT and case-sensitive APFS on macOS, and vfat on Linux.

## Further reading

- [Oracle fixtures](docs/ORACLE_FIXTURES.md): what each differential profile checks.
- [Real-world checks](docs/REAL_WORLD.md): `bench/realworld.cr`, repository comparisons and timings.
- [Capability matrix](docs/CORE_FUNCTION_COVERAGE.md) and [parity ledger](docs/PARITY_LEDGER.md): implementation status and remaining gaps.
- [Capability boundary](docs/CAPABILITY_BOUNDARY.md): responsibilities of the library and its caller.
- [Semantic namespaces](docs/SEMANTIC_NAMESPACES.md): API naming and ownership.

## License

MIT. See [LICENSE](LICENSE).

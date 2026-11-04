# Git shard semantic ownership

This records the type names and responsibilities in `src/git`, its public
`require "git"`, the native specs and the opt-in tool adapter. The library has
no external users to keep compatible, so every name is chosen for the best API
and an earlier name is replaced, never aliased. Git wire strings, Git
environment names and OS paths keep their Git-defined spelling.

## Rules

- `Repository` exposes Git's top-level commands as verbs (`commit`, `switch`,
  `reset`, `restore`, `merge`, `rebase`, `fetch`, `push`, `log`, ...). A family
  of subcommands is a handle named for what it manages (`refs`, `branches`,
  `tags`, `remotes`, `stash`, `recovery`); a prefix such as `stash_` or
  `_remote` on a method name means the handle is missing. An operation that can
  stop for conflicts is a verb with arguments and, without them, a handle on
  the operation in progress (`merge("topic", ...)` / `merge.abort`).
- Implementation stays where it was written, as `protected` methods, which
  only code inside `Git` can call. Internal components and plumbing that the
  white-box specs drive directly are `# :nodoc:` instead.
- A command or handle owns its values (`Merge::Result`, `Stash::Applied`) and
  its errors, which are named for what happened (`PartialPublication`,
  `EmptyCommit`).
- Public results are records or small structs, not tuples, except natural
  pairs that read best destructured (`ahead_behind`, config `-c` pairs and
  byte offsets from the pack writer). Object types are `ObjectType`, not
  strings.
- Budgets are keyword arguments with defaults, and cancellation is a
  `check : Proc(Nil)?` keyword, never a required block.
- One owner per source file.

## Implemented decisions

| ID      | Baseline owner                                                 | Decision / owner now                                                              | Reason                                                                                                            |
| ------- | -------------------------------------------------------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| N155-01 | `Git::Store`                                                   | `Git::Repository`                                                                 | Selects repositories and provides the inspection API as well as storage                                           |
| N155-02 | `Git::Objects`, `Git::Packs`                                   | `Git::ObjectDatabase`, `Git::ObjectDatabase::PackFiles`                           | One object database handles loose and packed objects; its packed-file component handles pack lookup and decoding |
| N155-03 | `Git::Snapshot`                                                | `Git::HeadTree`                                                                   | Reads committed HEAD paths without capturing an independent snapshot                                               |
| N155-04 | Commit parsing on `Snapshot`                                   | `Git::Commit.read`                                                                | Parses and validates commit values separately from tree navigation                                      |
| N155-05 | `Store` index parser and staged comparison                     | `Git::Index`, `Index::{Entry,Change,FileComparison}`                              | Decodes the per-worktree staging area, compares it with HEAD and holds the results                                    |
| N155-06 | `Store` working-file reader and status                         | `Git::WorkingTree`, `WorkingTree::{Change,FileComparison}`                        | Keeps on-disk file identity and status separate from index state and linked-worktree administration      |
| N155-07 | `Git::Safety`                                                  | `Git::Repository::Admission` with `Identity`                                      | Checks protected ownership/bare-repository admission when opening a repository; does not handle general tool/OS security                       |
| N155-08 | Config result + file parsing + typed decoding in `Git::Config` | `Config` result, private `Config::Loader`, `Config::Key` and `Config::Value`      | The loader holds mutable byte/entry/include state; the result provides effective queries and provenance; pure helpers handle grammars  |
| N155-09 | Flat Git subsystem source filenames                            | Matching repository/object/commit/head/index/working-tree/admission source owners | Source files follow component responsibilities; public `require "git"` remains unchanged     |

`Git::Repository` keeps `staged_changes`, `staged_file`, `working_changes` and
`working_file` as its inspection verbs (N157-09). The index and working-tree
implementations no longer reopen `Repository` to hold parsers, filesystem
traversal or comparison state. Each component is constructed with
explicit inputs selected by the repository; it reads no ambient `GIT_*` or home
scope. The tool adapter uses the same read-only operations on `Repository`.

## Remote, pack and history decisions

The remote, pack, history and maintenance code added after N155 was reviewed
against the same rules: value types live under the command or component that
produces them (as `Merge::Result`, `Reset::{Mode,Result}` and `Stash::Entry`
do), errors are named for what happened rather than suffixed `Error` (as
`PartialPublication` and `Recovery::Conflict` are), each source file holds one
owner, and there are no compatibility aliases.

| ID      | Baseline owner                                                                                  | Decision / owner now                                                                                         | Reason                                                                                                                          |
| ------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| N156-01 | `Git::Transport::Base` in a `Transport` module                                                   | `Git::Transport` abstract class; `Local`, `HTTP`, `Command`, `SSH`, `Daemon` subclass it                      | A transport is the thing callers hold; `Base` named no responsibility                                                            |
| N156-02 | `HTTPConnection`, `Local::LocalConnection`, `ProcessConnection`, `SocketConnection`              | `Transport::{HTTP,Local,Command,Daemon}::Connection`, sharing `Transport::StreamConnection`                    | Each connection belongs to the transport that opens it                                                                          |
| N156-03 | `Transport::AuthenticationError`, `ConnectionError`; `Protocol::ProtocolError`, `RemoteError`     | `Transport::{AuthenticationFailure,ConnectionFailure}`, `Protocol::{Violation,RemoteFailure}`                 | Errors name what happened; `Protocol::ProtocolError` repeated its namespace                                                      |
| N156-04 | `Protocol::UploadPack` (server), `V2Client`, `Negotiator`, `FetchOutcome`; `Protocol::ReceivePack` (server) with push wire code in `Repository#push_to` | `Protocol::UploadPack::{Server,Client,Negotiator,FetchOutcome,WantPolicy}`, `Protocol::ReceivePack::{Server,Client,Report,Command,Options}`, abstract `Protocol::Server` | Each service owns both ends of its conversation; the local transport and HTTP handler serve any `Protocol::Server`                |
| N156-05 | `Protocol::SidebandReader`, `SidebandWriter`; `Protocol.zero_id`                                  | `Protocol::Sideband::{Reader,Writer}`; `ObjectId.zero`                                                        | Side-band is one framing with two directions; the null ID is object identity, also used by reflogs                               |
| N156-06 | Pack type codes as integers, `PackFiles.read_entry_header`, `type_name`, `type_code`, `apply_delta` | `Pack::EntryType` enum, `Pack::EntryHeader.{read,encode}`, `Pack::Delta.apply`                                 | The entry format now has writers and an indexer as well as `PackFiles`; the delta format is applied and encoded in one place     |
| N156-07 | `Pack::Entry`, `Pack::IndexWriter.{idx,rev}`, `Pack::Received`, `Delta::Index`, `Inflate`        | `Pack::IndexEntry`, `Pack::IndexFile.encode`, `Pack::ReverseIndexFile.encode`, `Pack::Published`, `Delta::SourceIndex`, `Inflater` | Names say which file or role they describe; `Index` alone collided with `Git::Index`                                           |
| N156-08 | `Repository#receive_pack`                                                                        | `Repository#index_pack`                                                                                       | It is Git's index-pack; `receive_pack` collided with the receive-pack service                                                   |
| N156-09 | `Git::Reachability::{Walker,Item,CommitInfo,DateQueue}`, `Reachability.each_tree_entry`          | `History::{RevisionWalker,ReachableObject,CommitNode,DateQueue}`, `Tree.each_entry`                           | Revision walking is history; decoding a tree body belongs beside `Tree.encode`                                                  |
| N156-10 | Revision parsing, peeling and range sets as private `Repository` methods                         | `Revision::Parser`, `Revision.peel`, `Revision.ranges`; `Repository#rev_parse` delegates                      | Parsing state no longer reopens the repository facade, as N155 required of the index and working tree                           |
| N156-11 | `Git::TreeChange` and private tree comparison on `Repository`                                    | `Git::TreeDiff` with `TreeDiff::Change`, beside `TextDiff`                                                    | Tree and text differences are parallel components                                                                               |
| N156-12 | `Git::{FetchUpdate,FetchResult,PushUpdate,PushResult,PullMode,PullResult,RepackResult,GcResult,FsckReport}` | `Fetch::{Update,Result,Mapping}`, `Push::{Update,Result}`, `Pull::{Mode,Action,Result}`, `Repack::Result`, `Gc::Result`, `Fsck::Report` | Command modules own their values, as `Merge`, `Rebase` and `Reset` do; `Pull::Action` replaces a bare `Symbol`                  |
| N156-13 | `Git::Refspec` with `REV_PARSE_RULES` and `dwim`; `Git::BranchInfo`; `Repository::PSEUDO_REFS`   | `Remote::Refspec`; `RefName::REV_PARSE_RULES` and `RefName.expand`; `References::Branch`; `References::PSEUDO_REFS` | Refspecs configure remotes; short-name expansion is ref-name grammar used by rev-parse as well as fetch and push               |
| N156-14 | `set_symbolic_ref(expected_target: String? \| Symbol = :any)`                                    | `set_symbolic_ref(expected_target: String? = nil, create_only: false)`                                        | Explicit options instead of a symbol sentinel                                                                                   |
| N156-15 | Mixed source files (`transport/process.cr`, `protocol/client.cr`, `maintenance/maintenance.cr`, pull in `references/branches.cr`, checkout in `remote/clone.cr`) | One owner per file: `transport/{command,ssh,daemon}.cr`, `protocol/{advertisement,sideband,server}.cr`, `protocol/{upload_pack,receive_pack}/{server,client}.cr`, `maintenance/{repack,gc,fsck}.cr`, `references/{symbolic,pack_refs}.cr`, `remote/pull.cr`, `workflow/checkout/populate.cr`, `tree_diff.cr` | Source files follow component responsibilities (N155-09)                                                                        |

`Repository` keeps the verbs (`fetch`, `push`, `pull`, `clone`, `index_pack`,
`rev_parse`, `diff_trees`, `repack`, `fsck`, ...). N157 below supersedes the
N156 names that later moved onto handles (`References::Branch`,
`set_symbolic_ref`).

## Repository surface decisions

With no users to keep, the `Repository` facade was redesigned rather than
renamed. It had 136 public methods; it now has about 70, with the rest on
handles or hidden.

| ID      | Baseline | Decision / owner now | Reason |
| ------- | -------- | -------------------- | ------ |
| N157-01 | `update_ref`, `delete_ref`, `change_refs`, `update_refs`, `set_symbolic_ref`, `delete_symbolic_ref`, `detach_head`, `pack_refs`, `expand_ref`, `references`, `resolve_ref?`, `symbolic_ref?` | `repo.refs` (`References`): `update`, `delete`, `apply`, `set_symbolic`, `delete_symbolic`, `detach_head`, `pack`, `expand`, `list`, `resolve?`, `symbolic_target?`; `update_refs` removed | One handle for `update-ref`, `symbolic-ref`, `for-each-ref` and `pack-refs`; `apply` already covered every `update_refs` batch |
| N157-02 | `change_refs_recoverably`, `change_index_and_refs_recoverably`, `commit_index_changes_recoverably`, `recover_refs`, `recover_index_and_refs`, `pending_ref_*`, `finish_ref_finalization` | `repo.recovery` (`References::Recovery`): `apply` (two overloads), `commit`, `resume`, `pending`, `pending_finalizations`, `finish_finalization` | The journal is one thing; `resume` finishes any journal, with or without an index image |
| N157-03 | `branches`, `create_branch`, `delete_branch`, `rename_branch`, `branch_upstream`, `set_branch_upstream`, `upstream_tracking_ref`; `References::Branch` | `repo.branches` (`Branches`) returning `Git::Branch` with `Branch::Upstream`; `Remote#tracking_ref` | `git branch` is one family; an upstream is a value, not a `{remote, ref}` tuple |
| N157-04 | `tags`, `create_tag`, `delete_tag`; `add_remote`, `remove_remote`, `rename_remote`, `set_remote_url`, `remote`, `remote?`, `remote_names` | `repo.tags` (`Tags`: `list`, `create`, `delete`); `repo.remotes` (`Remotes`: `add`, `remove`, `rename`, `set_url`, `[]`, `[]?`, `names`) | `git tag` and `git remote` subcommands |
| N157-05 | `stash_push`, `stash_list`, `stash_show`, `stash_apply`, `stash_pop`, `stash_drop`; `Stash::Result::{Apply,Pop}` | `repo.stash` (`Stash`): `push`, `list`, `show`, `apply`, `pop`, `drop`; `Stash::Applied`, `Stash::Popped` | `git stash` subcommands; a `Result` module holding two records named nothing |
| N157-06 | `merge_three_way`, `merge_fast_forward`, `merge_*`, `rebase_*`, `sequencer_*`, `cherry_pick_*`, `revert_*`; `merge_state?` tuple; `Sequencer::EmptyResult` | `merge(source, ...)`, `fast_forward`; without arguments `merge`, `rebase`, `cherry_pick`, `revert` and `sequencer` are handles (`state?`, `in_progress?`, `conflicts`, `continue`, `skip`, `abort`); `Merge::State`; `Sequencer::EmptyCommit` | Mirrors `git merge x` and `git merge --abort`; the per-kind checks live in one `Sequencer` handle |
| N157-07 | `commit_staged`, `reset_head`, `reset_head_hard`, `reset_index_to`, `restore_paths`, `restore_staged_paths`, `checkout_branch`; the `commit(oid)` reader | `commit`, `reset` (hard is a `Reset::Mode`), `read_tree`, `restore`, `restore_staged`, `switch`; `read_commit` | Git's own verbs; `commit` belongs to the porcelain, so the reader is `read_commit` |
| N157-08 | `fetch` + `fetch_from(transport)`, `push` + `push_to(transport)`, `ls_remote(transport)` | `fetch`, `push` and `ls_remote` taking `remote : String \| Transport` | One verb each, as `clone` already did. Crystal fails to pick the transport overload when the other's first argument has a default |
| N157-09 | `head : {String?, String?}` and `head_reference`; `object(oid, max, depth, seen, &)`; `object_header : {String, Int64}`; `staged_changes` and `working_changes` tuples; `head_entry`, `head_directory` and `read_head_file` tuples; positional budgets with a required block | `head : References::Ref`; `read_object : RawObject` and `object_header : ObjectHeader` with `ObjectType`; `Index::ChangeList` and `WorkingTree::ChangeList` (`Indexable`, `truncated?`, `ignored`); `Tree::Entry`; keyword budgets and `check:` | Named values instead of positional tuples; recursion state and a second cancellation convention no longer leak |
| N157-10 | `history` (topological, exact roots) beside `log` (date order, ranges) | `log(revisions, order: History::Order, max_commits:)` returning `History::Result` | One history verb, with ranges and both orders |
| N157-11 | `check!`; `refs(scope, max)`; `pack_files`, `object_ids_with_prefix`, `checkout_*`, `populate_worktree` | `revalidate!`; removed (use `refs.list`); `protected` | `check!` named nothing; the scoped listing duplicated `refs.list`; the rest is plumbing for other components |
| N157-12 | Public helpers on `Checkout`, `Merge`, `Sequencer`, `Revision`, `IndexRestore`, `References::Recovery`, `Repository::Admission`, `Index`, `WorkingTree`, `HeadTree` | `protected`, or `:nodoc:` where white-box specs call them; `Location`, `Metadata`, `ObjectDatabase`, `HeadTree`, `DescriptorPath`, `Revision`, `RevisionWalker`, `Transaction` and internal plans `:nodoc:` | The documented API is what callers use |
| N157-13 | `Location::AdmissionSite`; string object types in `write_tag`, `Tag.encode`, `ReachableObject` and the pack plumbing; the `SSH.parse` tuple | `Repository::Admission::Site`; `ObjectType`; `SSH#user`, `#host`, `#port` and `#path` | The admission hook's argument belongs with `Admission::Identity`; an invalid object type no longer type-checks |

## Local workflow decisions

| ID      | Baseline | Decision / owner now | Reason |
| ------- | -------- | -------------------- | ------ |
| N158-01 | `stage_file` and `remove_from_index` only | `stage(paths, tracked_only:)` (`add -A`/`-u`) and `remove(paths, cached:, force:, recursive:)` (`rm`), raising `Staging::{IgnoredPaths, PathspecMismatch}` and `Removal::{Refused, NotRecursive, PartialRemoval}`; `stage_file` and `remove_from_index` stay as single-path primitives | Git's verbs over many paths in one index write; the primitives return a blob ID or skip the safety checks, which the verbs cannot |
| N158-02 | `TextDiff.unified` over one `staged_file`/`working_file` comparison | `diff(old, new, cached:)` and `commit_patch(revision)` returning `Git::Patch` (`Indexable(Patch::File)`); `TextDiff` is the `:nodoc:` engine | One verb with `git diff`'s forms; a patch is a value with per-file sections, not a string the caller assembles |
| N158-03 | `push(force:)` only | `push(lease: Push::Lease)`; `Lease.tracking(refs)` and `Lease.expect({ref => oid?})` | `--force-with-lease`'s two forms as constructors; a lease is pushed with the refs it covers |
| N158-04 | `reset(log:)`, `fast_forward(log:)`, `branches.create(log:)` taking a `References::LogEntry` | `actor : Signature?`; the command writes Git's own message | The message is the command's, as in Git; `refs.update(log:)` keeps the free-form entry (`update-ref -m`) |
| N158-05 | `switch(name)` for an existing branch only | `switch(target, create:, from:, detach:, guess:, track:, actor:)`; `Checkout::Result#reference` is nil when detached | `git switch`'s flags on one verb; a created branch is published with the checkout, not before it |
| N158-06 | none | `amend(committer:, author:, message:, allow_empty:)` beside `commit` | Author and message are optional only when amending, which a `commit(amend: true)` flag could not express in the signature |
| N158-07 | `History.resolve_commit` (branch and tag names, `~`/`^`) and `Revision.resolve_commit`; `refs.resolve?` for full names only | `History.resolve_commit` peels `rev_parse`; `Revision.resolve_commit` removed; `refs.resolve?` also reads HEAD and the other pseudo-refs | Every command taking a commit understands `origin/main`, `ORIG_HEAD` and `@{u}` as `git` does |

## Names retained

| Name                                        | Actual owner and rationale                                                                                    |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `Git::Location` (`:nodoc:`)                 | Selects repository/admin/common/worktree paths, discovery and identity checks; separate from Git ref metadata |
| `Git::Metadata` (`:nodoc:`)                 | Owns repository object-format validation and loose/packed ref resolution; no working-tree traversal           |
| `Git::ObjectId` / `ObjectId::Format`        | Represents Git object identity and hash format                                   |
| `Git::PathBytes`                            | Preserves Git pathname bytes, handles presentation and validates paths without assuming Unicode    |
| `Git::RefName`                              | Git-specific refname grammar and validation                                                                   |
| `Git::Ignore` / `Ignore::Rule`              | Ignore-rule interpretation/cache and rule identity                                                            |
| `Git::TextDiff` (`:nodoc:`)                 | xdiff's line diff (Myers, heuristics, compaction, indent heuristic) behind `Git::Patch`                       |
| `Git::Config::{Scope,Source,Entry,Context}` | Represent configuration scope, origin, effective entry and include context                              |
| `Git::Config::FileEditor`                   | Edits caller-selected config files with an exclusive `.lock` and atomic replace                      |
| `Git::Error`                                | Shared Git-native error type used by all read and write subsystems                                            |
| `Git::Remote` / `Remote::TagMode`           | One configured remote and how it follows tags                                                                 |
| `Git::Protocol::{PktLine,Advertisement,RemoteRef}` | Wire framing, a service's first message and a ref as a remote reports it                               |
| `Git::Pack::{Writer,Builder,Indexer,StreamReader}` | Pack stream encoder, pack-objects, index-pack and the byte-accounting stream parser                     |
| `Git::Server::HTTPHandler`                  | An `HTTP::Handler` serving smart HTTP; opt-in `require "git/server/http_handler"`                             |

The path-name classifier marks all declared source paths as portable. The
post-refactor inventory found no repeated-role sibling families.
The remaining `Index#index_*` and `Metadata#read_*` methods handle binary-index
and metadata-ref operations; their prefixes alone do not justify separate types.

## Deferred work and evidence limits

- Every porcelain method still takes its own `max_*` budgets. A repository-wide
  `Limits` value would shorten every signature; it is a larger change to how
  callers bound work, so it is left for a separate decision.
- Revision resolution has two entry points: `Revision::Parser` (`rev_parse`)
  and `History.resolve_commit`, which peels `rev_parse`'s answer to a commit.
  `Revision.resolve_commit`, a third, narrower grammar, is gone (N158-07).
- `WorkingTree::Change#status` and `Index::Change#status` are strings; they
  should be an enum as `ObjectType` is.
- `ObjectDatabase::PackFiles` keeps pack-index lookup and pack/delta decoding
  together. The entry format and delta application moved to `Git::Pack` once
  writers and an indexer used them (N156-06); index lookup and decoding still
  share the cached index state, so they stay together.
- Linked-worktree inventory (locked/prunable records) is not implemented.
  `WorkingTree` does not manage that administrative lifecycle.
- Complete Git config grammar, config edit selectors, split/sparse indexes,
  alternate object directories and reftable remain feature/parity work. This
  naming review did not establish defects in them.
- Hostile concurrent metadata replacement and non-Linux platform behavior are
  outside current compiler and fixture evidence. Paths are all classified
  portable; this is not runtime proof for macOS/Windows.

## Boundary invariants

Standalone Git has no dependency on a host application, workspace manager,
Git subprocess, libgit2 or model permission system. The `Git::Config::FileEditor` writer remains an opt-in
native library API; the tool adapter remains read-only. The default `require "git"` must
reach every production implementation; source-only consumers must compile.

## Tree encoding

`Git::Tree::Entry` and `Git::Tree.encode` serialize Git trees byte for byte.
They do not perform HEAD traversal, index staging or working-tree I/O; those
remain in `Git::HeadTree`, `Git::Index` and `Git::WorkingTree`.
`Git::ObjectDatabase` publishes loose blobs and trees;
`Git::Repository` forwards explicit write calls without importing host policy.

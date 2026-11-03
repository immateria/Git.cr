# Git shard semantic ownership

This records the type names and responsibilities in `src/git`, its public
`require "git"`, the native specs and the opt-in tool adapter. There are no
compatibility aliases. Git wire strings, JSON keys, tool/action names, Git
environment names and OS paths keep their Git-defined spelling.

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

`Git::Repository` retains thin methods (`staged_changes`, `staged_file`,
`working_changes`, `working_file`) for convenience. The index
and working-tree implementations no longer reopen `Repository` to hold parsers,
filesystem traversal or comparison state. Each component is constructed with
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
`rev_parse`, `diff_trees`, `repack`, `fsck`, ...). It gained thin reads that
the extracted components need: `index_entries`, `object_ids_with_prefix`,
`git_directory`, `common_directory` and `shallow_commits`.

## Names retained

| Name                                        | Actual owner and rationale                                                                                    |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `Git::Location`                             | Selects repository/admin/common/worktree paths, discovery and identity checks; separate from Git ref metadata |
| `Git::Metadata`                             | Owns repository object-format validation and loose/packed ref resolution; no working-tree traversal           |
| `Git::ObjectId` / `ObjectId::Format`        | Represents Git object identity and hash format                                   |
| `Git::PathBytes`                            | Preserves Git pathname bytes, handles presentation and validates paths without assuming Unicode    |
| `Git::RefName`                              | Git-specific refname grammar and validation                                                                   |
| `Git::Ignore` / `Ignore::Rule`              | Ignore-rule interpretation/cache and rule identity                                                            |
| `Git::TextDiff`                             | Computes bounded text-only diffs; does not provide a general binary/merge engine                                        |
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
Git subprocess, libgit2 or model permission system. Existing JSON field names,
status labels, action digests, registered tool names and file access enforcement
must remain unchanged. The `Git::Config::FileEditor` writer remains an opt-in
native library API; the tool adapter remains read-only. The default `require "git"` must
reach every production implementation; source-only consumers must compile.

## Tree encoding

`Git::Tree::Entry` and `Git::Tree.encode` serialize Git trees byte for byte.
They do not perform HEAD traversal, index staging or working-tree I/O; those
remain in `Git::HeadTree`, `Git::Index` and `Git::WorkingTree`.
`Git::ObjectDatabase` publishes loose blobs and trees;
`Git::Repository` forwards explicit write calls without importing host policy.

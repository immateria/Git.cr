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

The path-name classifier marks all declared source paths as portable. The
post-refactor inventory found no repeated-role sibling families.
The remaining `Index#index_*` and `Metadata#read_*` methods handle binary-index
and metadata-ref operations; their prefixes alone do not justify separate types.

## Deferred work and evidence limits

- `ObjectDatabase::PackFiles` keeps pack-index lookup and pack/delta decoding
  together. Split them only when independent format support, performance or
  state ownership justifies it. A cosmetic `Index`/`Decoder` namespace split
  would not establish a design improvement.
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

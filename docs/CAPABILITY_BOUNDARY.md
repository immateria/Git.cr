# Git library behavior versus host authorization

The `git` library implements Git behavior; the host decides what a caller may
do. This document describes that boundary. It does not grant permission or
describe a shipped external-execution API.

The `git` source must remain usable without a host application, workspace
manager, model clients, UI providers or host policy. Git semantics and
byte-exact outputs belong in the library, outside the model-facing adapter.

## Library scope

The `git` shard is intended to become a general native Crystal implementation
of Git. It targets Git's repository, object, ref, index, worktree, diff, merge,
configuration, hook, transport and maintenance semantics, including reading
and writing. Missing mutations, network transport, executable hooks/filters,
backends and large-repository performance remain unfinished work. A host's
restrictions do not exclude them from the library's scope. Git compatibility
is tested against upstream Git; host tools cannot substitute for native
parity. Applications must be able to use `require "git"` without importing a
host, a workspace manager, agent permissions or an optional tool adapter.

Native Crystal applications should eventually have typed, composable extension
APIs for replaceable object storage and caches; filesystem/worktree backends;
transport, authentication and credential providers; diff/merge/filter drivers;
Git hooks and explicit native callbacks; reference and index transaction
observers; tracing, progress and cancellation. Add each API with a concrete
implementation that defines deterministic ordering, error propagation,
lifecycle, transaction and concurrency rules. These APIs must work for ordinary
applications without a host. External programs and network access remain in
scope, with explicit, testable invocation and safe behavior when required
providers are missing. An agent's policy can prohibit an operation that the
library supports.

Keep resource budgets configurable; they must not permanently limit Git support
to small repositories. Existing parser/diff limits are implementation gaps;
the goal is scalable algorithms, streaming I/O and reasonable limits that
callers can tune. Preserve byte-accurate Git object and path semantics, including
non-UTF-8 Linux filenames, regardless of model/UI presentation restrictions.

## Optional host adapter

A host should use the library through a separate, optional adapter. The adapter
can live in the host until it is extracted into its own shard. It maps Git
reads, writes, network access, execution and destructive effects to narrowly
scoped grants for repositories, worktrees, paths, refs, remotes and credentials.
It also handles approvals, limits, cancellation, redaction and audit receipts.
Those grants must come from independently trusted authority. One operation can
need several grants: fetch writes objects and refs and uses the network;
commit writes objects and refs and may invoke hooks/signers.

Authorization belongs to the adapter/host, not `Git::Repository` or its storage
collaborators. The adapter may default to read-only and expose nothing unsafe.
Those choices do not narrow the library's scope. Native read/write APIs can
precede any corresponding agent tool.

## Effects requiring opt-in

| Operation family                            | Library owner                                                                                                                   | External effect requiring opt-in                                                      | Host policy                                                        |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Read objects, refs, index, worktree, config | `git`                                                                                                                           | filesystem read; optional promisor fetch must not happen implicitly                   | opt-in scoped read, bounded output and redaction                   |
| Write objects, index, refs, reflogs, config | `git`                                                                                                                           | administrative filesystem writes with Git-compatible lock/publish and error semantics | narrow per-operation grants; exact repository and state identities |
| checkout, reset, branch, merge/rebase       | `git`                                                                                                                           | worktree/ref/index edits and collision/recovery state                                 | destructive operations denied/approval required by default         |
| hooks, filters, merge/diff drivers, signers | `git` implements Git semantics with configurable runner and callback providers; standalone applications select execution policy | external executable, environment, filesystem and credential effects                   | denied unless separately host-authorized by the optional bridge    |
| remote clone/fetch/push                     | `git` implements protocol/refspec behavior with injectable transport and credential providers                                   | transport connections, authentication, remote refs                                    | specific endpoint/ref/operation grants and credential broker       |
| maintenance, prune, pack/gc                 | `git`                                                                                                                           | potentially large I/O and garbage collection                                          | host-controlled administrative grants and resource budgets         |

## Required behavior

1. If the native `git` library cannot handle a repository or feature, it must
   not fall back implicitly to an executable, shell or libgit2. The
   external-process provider is separately identified and explicitly authorized.
   Its results do not count as native parity.
2. `git` returns raw, unredacted supported data. It distinguishes invalid,
   missing, unsupported, corrupted, conflicting, resource-exhausted and
   external-provider-required states. A policy denial from the adapter does
   not describe the repository's state.
3. Local mutations must follow Git's refs/index/object transaction boundaries.
   They must not promise globally atomic repository reads, rollback of all
   file writes or immunity to hostile process races.
4. Repository-controlled hooks, filters, signing commands, SSH, transport and
   credential helpers remain part of the planned Git support. External effects
   require explicit, configurable executor/transport/credential providers with
   defined inputs, timeouts, cancellation and outcomes. There is no implicit
   shell/libgit2 fallback. A trusted standalone application may enable
   executable Git behavior. An untrusted host caller cannot authorize itself;
   the bridge/host supplies independently trusted grants.
5. The host applies its action/approval/lease model to verified library actions,
   using its own authority. It must not insert permission checks into the `git`
   provider. The adapter's current nine native and three process-inspection
   tools remain read-only and opt-in while mutation semantics are built.
6. The library may support an operation before a host-facing tool exists or
   when agent use is prohibited. Host policy is not a reason to remove it.

## Runner and transport requirements (not implemented)

For each Git feature that executes an external program, define:

- Typed argv, input, stdout, stderr and outcome categories.
- Git-defined working directory and environment.
- Timeout and cancellation behavior.
- Filesystem and network resource scope, and credential handling.

The library can supply composable executors/providers for trusted standalone
callers without requiring a host. A missing provider must never be reported as
success or a clean repository. The optional host bridge supplies trusted grants
and audit provenance separately; its tests must prove that denied actions have
no side effects. Repository configuration and model tool calls must not be able
to broaden those grants.

## Current code status

The native implementation currently makes no runtime Git subprocess calls and
runs no hooks, filters, signing or network operations. That describes the current
implementation, not a permanent restriction on the library.

`Git::Config::FileEditor` edits individual files using `.lock` and rename.
`Git::Repository#write_blob`, `#write_tree`, `#write_commit` and `#write_tag`
publish immutable loose blob/tree/commit/tag objects for SHA-1/SHA-256
repositories without executable Git. Any library caller with filesystem write
permission can use them. `Git::Tree::Entry` and `Git::Tree.encode` provide
canonical tree representation; `Git::Signature`, `Git::Commit.encode` and
`Git::Tag.encode` provide native object-header and identity/date formats.

Index and ref writes support:

- Bounded index-v2/v3/v4 staging, preservation of supported flags and recursive
  index-tree writing.
- Single-ref CAS and deletion, including packed-ref rewriting and ref-specific
  reflog removal.
- Coordinated multi-ref update preflight/locking and mixed direct-ref
  create/update/delete batches, with packed-refs rewriting and diagnostics for
  partial publication.
- An opt-in bounded, versioned durable redo journal with idempotent reflog
  completion and version-3 exact-index-image forward recovery for mixed refs:
  `change_refs_recoverably` / `recover_refs`,
  `change_index_and_refs_recoverably` / `recover_index_and_refs`, and
  `commit_index_changes_recoverably`.
- Optional reflog append in ordinary non-recoverable writes.

The redo journal records recoverable intent. It provides neither global crash
atomicity across refs and index, rollback nor an agent grant. Git compatibility
remains partial, with no signing, credential or hook execution.

The low-level object writers do not update the index/refs. Separate APIs perform
those mutations: `stage_blob`, `stage_file`, `write_index_tree`, `update_ref`,
`update_refs`, `change_refs`, `delete_ref`, `remove_from_index` and
`commit_staged`. They do not change host permissions, and the host registers no
model-facing mutation tool. The opt-in external-process provider uses a trusted
Git executable for three read-only operations under a separate policy. The full
external-runner and mutation-grant designs are not implemented.

## Recovery guard boundary

The library's opt-in durable recovery transactions share a
per-common-directory advisory lock and refuse new durable transactions until
pending journals are resolved. Ref and index desired-state checks before
journal deletion detect observable external Git changes; they do not exclude
ordinary Git processes, close the final check/unlink race, implement signed
journals or confer host tool authorization. Ordinary native mutation APIs
and all host-facing Git tools retain their existing boundaries.

## Repository selection boundary

`Git::Repository` follows Git's default behavior for ordinary
`.git` directories and valid `.git` pointer files; it does not consult
process `ENV`. `Git::Repository.from_environment(cwd, host_supplied_hash)` accepts
`GIT_DIR`, `GIT_COMMON_DIR`, and `GIT_WORK_TREE` supplied explicitly by a trusted
caller. `Repository.new(..., discover: true)` searches ancestors and may be bounded
with `discovery_ceiling:`. These APIs do not grant agent permissions.

The adapter's nine opt-in native Git tools construct `Git::Repository` with
`follow_gitfile: false`, retaining the original explicit
`linked_worktree_admin_dir:` host capability. No model input can supply a
Git metadata directory, working directory, common directory, or discovery root.
The adapter does not widen a host workspace lease to match `core.worktree`.
This is verified by the existing linked-worktree refusal and authorized
positive fixtures in the adapter's own spec suite.

### Descriptor-confinement boundary

The standalone Git shard has a Linux-specific internal directory-FD helper
for owned finalization locks, index publication and single-ref CAS. It changes
neither the host-facing Git tool set nor any trusted host grant.
This does not establish safety or atomicity for every Git write path, hostile
final-component races or cross-file journaling. Other supported platforms
and OS-specific open flags have not been verified.

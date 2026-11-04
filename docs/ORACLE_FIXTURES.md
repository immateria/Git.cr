# Native Git parity fixtures

The recorded profile is Git 2.47.3, Crystal 1.21.0, Linux x86-64, Git files
refs and isolated temporary repositories. `GIT_ORACLE_BINARY` selects the Git
binary (default: `git` on `PATH`); the oracle refuses any other version.
These fixtures were run in a Linux sandbox, not on macOS. Record the actual
runtime versions on each rerun.

- Every `GitOracle.run` call uses `clear_env: true`. HOME/XDG/global/system
  config, locale/TZ, author and committer are fixed. Ambient credentials and
  interactive prompts are disabled, the template directory is explicitly
  empty, and SSH is refused. Fixture repositories use generated temporary
  directories deleted on exit. Only test code invokes the oracle binary.
- `spec/support/git_oracle.cr` captures raw stdout/stderr/exit code and compares
  exact bytes, including NULs. `assert_bytes!` raises `GitOracle::Mismatch` on
  any mismatch. P01-O01 supplies a wrong expected OID to check that the
  assertion fails.
- The P01 cases below are `Git creates -> Crystal reads`. Writer specs for
  objects, index, refs, config, merge and stash add `Crystal writes -> Git accepts`
  cases through the same oracle; this table does not list them.

| Fixture ID | Repository profile                              | Git oracle commands                                                             | Verified property                                                                                               | Negative behavior                                                                                 |
| ---------- | ----------------------------------------------- | ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| P01-O01    | SHA-1 files refs; loose file                    | `hash-object`                                                                   | byte-exact output, deterministic object ID                                                                      | deliberate mismatch raises `Mismatch`                                                             |
| P01-O02    | SHA-1 files refs; packed refs and detached HEAD | `add`, `commit`, `branch`, `tag`, `pack-refs`, `rev-parse`, `checkout --detach` | HEAD, side/tag ref IDs and committed content equal Git                                                          | both symbolic/detached paths compared                                                             |
| P01-O03    | SHA-1 files refs; default index                 | `add`, `ls-files --stage -z`, `hash-object`                                     | exact binary index-stage record including terminal NUL                                                          | wrong bytes fail strict equality                                                                  |
| P01-O04    | SHA-1 files refs; local ignored directory       | `check-ignore`, `add`                                                           | ignored-parent rule and native change classification                                                            | appended corrupt index rejected                                                                   |
| P01-O05    | SHA-1 files refs; linked worktree               | `worktree add`, `rev-parse`                                                     | independently opened linked HEAD and common object store                                                        | restricted `follow_gitfile: false` requires selected admin; default library follows valid gitfile |
| P03-O01    | SHA-256 files refs; loose objects and index     | `init --object-format=sha256`, `add`, `commit`, `rev-parse`                     | SHA-256 HEAD, commit, tree, blob and staged state                                                               | malformed names/metadata separately tested                                                        |
| P03-O02    | SHA-256 files refs; packed objects and refs     | `pack-refs`, `gc`, `rev-parse`, `hash-object`                                   | SHA-256 packed history/refs, staged OIDs and worktree content hash                                              | corrupted pack/index separately tested                                                            |
| P03-O03    | SHA-256, index v2/v3/v4                         | `update-index --index-version`, `--skip-worktree`, `ls-files --stage -z`        | real Git index headers, OIDs and stages match Crystal for three index layouts                                   | deliberately avoids an invalid synthetic index v3 header                                          |
| P03-O04    | SHA-256 raw blob/OID                            | `hash-object`                                                                   | binary bytes hash to exact SHA-256 typed object name                                                            | reject short, long, uppercase, path-looking and absent OIDs                                       |
| P03-O05    | SHA-256 packed object                           | `gc`, `rev-parse`, `cat-file`                                                   | unmodified packed blob round-trips                                                                              | tampered `.idx` or `.pack` trailer rejects                                                        |
| P03-O06    | SHA-256 config                                  | `init --object-format=sha256`                                                   | git-native object format selected by config                                                                     | version-0 SHA-256, format drift, unsupported refStorage rejected                                  |
| P03-O07    | SHA-256 REF_DELTA                               | `pack-objects --no-delta-base-offset`, `verify-pack -v`, `cat-file`             | actual Git-produced 32-byte reference-delta base OIDs decode exactly                                            | fixture requires a real delta, not inferred from requested flags                                  |
| P03-AD01   | SHA-256 adapter tools                          | `rev-parse`, `ls-files`, `commit`                                               | `git_head`, `git_refs`, `git_history`, `git_file` and `git_staged` retain authorization and correct SHA-256 IDs | invalid repository config fails                                                                   |

| Fixture ID | Repository profile                              | Git oracle commands                                                             | Verified property                                                                                               | Negative behavior                                                                                 |
| ---------- | ----------------------------------------------- | ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| P05-O01 | SHA-1 and SHA-256 bare clones                | `clone --bare`, `rev-parse`, committed-file lookup | bare HEAD/objects without working root; worktree reads explicitly unavailable | bare worktree accesses refuse                       |
| P05-O02 | external `--separate-git-dir` | `init --separate-git-dir`, `rev-parse` | default library gitfile follow, selected admin, format/refs/index, explicit override | restricted mode refuses implicit external metadata |
| P05-O03 | nested worktree discovery                    | `rev-parse`, nested `init`                         | nearest repo wins; ceiling prevents unbounded ancestors                       | selected discovery ceiling stops above repo         |
| P05-O04 | linked shared repository                     | `worktree add`, `update-ref`, `rev-parse`          | per-worktree index/HEAD and `refs/worktree/*` distinct from common refs       | corrupt reverse `gitdir` rejected                   |
| P05-O05 | relative selected git/worktree paths         | `rev-parse`, `symbolic-ref` with explicit env      | `GIT_DIR`/`GIT_WORK_TREE` values from trusted caller map correctly            | no implicit ENV inherited                           |
| P05-O06 | malicious metadata pointers                  | Git-generated + mutated `.git` files               | symlinks and missing gitfiles rejected without explicit override              | implicit symlink/dangling pointer refused           |
| P05-O07 | `core.worktree` external selection           | `git config core.worktree`, `rev-parse`            | selected worktree matches Git; no invisible scope widening                    | absent trusted selection refuses external root      |
| P05-O08 | bare `GIT_DIR` with explicit `GIT_WORK_TREE` | `clone --bare` + explicit environment              | effective repository is nonbare for selected worktree                         | no implicit use of configured bare root as worktree |
| P05-O09 | linked worktree with `GIT_COMMON_DIR`        | `rev-parse` with explicit env                      | environment path is cwd-relative; `commondir` file is admin-relative          | wrong relative env path fails                       |
| P05-O10 | replaced admin directory same pathname       | copy original metadata to new inode                | previously selected repository identity is invalidated                        | in-place same-path replacement rejected by `check!` |
| P05-O11 | relative `.git` pointer plus discovery       | `init --separate-git-dir`, `rev-parse`             | byte-exact relative admin resolution from nested worktree                     | restricted mode refuses pointer                     |
| P05-O12 | `core.worktree` vs explicit `GIT_WORK_TREE`  | `config`, `rev-parse` with/without env             | explicitly selected worktree takes precedence                                 | invalid automatic scope widening refused            |

These fixtures leave older/newer Git versions, reftable, split/sparse index,
complete multi-worktree inventory, global/included configuration, macOS/Windows,
mount-aware discovery and hostile concurrent mutation unverified. The P05
location tests cover specific cases, not full Git environment/config parity.
Each output comparison establishes behavior only for its stated profile.

## Pack, history, remote and maintenance fixtures

These specs use the same pinned oracle. The remote specs additionally run
`git http-backend` (behind a loopback `HTTP::Server` acting as a CGI host),
`git daemon`, `git upload-pack` and `git receive-pack` from the oracle's
installation; the native code never starts them itself.

| Fixture ID | Spec | Verified property |
| ---------- | ---- | ----------------- |
| PACK-O01 | `pack_spec.cr` | Indexing a Git-written delta pack (`repack -adf --depth=50`) yields `.idx` and `.rev` bytes identical to Git's, under SHA-1 and SHA-256 |
| PACK-O02 | `pack_spec.cr` | Native packs are accepted by `index-pack` and `verify-pack`, and the native `.idx` equals Git's for the same pack |
| PACK-O03 | `pack_spec.cr` | A `pack-objects --thin` pack received natively has its bases appended; `fsck --strict` and `verify-pack` pass; re-receiving publishes nothing new |
| PACK-O04 | `pack_spec.cr` | Truncated, corrupted and unresolvable thin packs are refused with nothing published |
| PACK-D01 | `pack_spec.cr` | Native deltas round-trip through the pack reader across empty, short, random and repetitive inputs |
| PACK-O05 | `pack_spec.cr` | Delta-compressed full and thin packs from `Pack::Builder` pass `index-pack --strict`, `--fix-thin` and `fsck --strict` |
| PACK-O06 | `pack_spec.cr` | `object_header` reports type and size like `cat-file --batch-check` for loose and deltified objects |
| REACH-O01 | `revision_walker_spec.cr` | `reachable_objects` equals `rev-list --objects` (with paths) for tips, exclusions, tags, trees and orphans; commit order equals `rev-list` |
| REACH-O02 | `revision_walker_spec.cr` | `ancestor?` equals `merge-base --is-ancestor` for every pair, including a clock-skewed commit |
| REMOTE-O01 | `remote_spec.cr` | Native clone over the local transport equals `git clone --no-local`: refs, symrefs, index, config, modes, symlinks, gitlinks; `fsck --strict` and clean `status` |
| REMOTE-O02 | `remote_spec.cr` | Incremental fetch with forced updates, new branches, tag following and prune equals `git fetch`/`fetch --prune`, including FETCH_HEAD bytes |
| REMOTE-O03 | `remote_spec.cr` | The real Git client clones, fetches, pushes (including forced and delete) and shallow-clones from the native HTTP handler |
| REMOTE-O04 | `remote_spec.cr` | The native client clones, fetches, pushes and shallow-clones against `git http-backend`, under SHA-1 and SHA-256 |
| REMOTE-O05 | `remote_spec.cr` | Push rules: up-to-date, tag protection without force, atomic failure, refusal of a checked-out branch by the native receive-pack |
| REMOTE-O06 | `remote_spec.cr` | Remote add/rename/remove match `git remote -v`, `git config` and tracking refs |
| REMOTE-O07 | `remote_spec.cr` | Refspec parsing, pattern mapping, DWIM and refusals |
| TRANSPORT-O01..O04 | `transport_spec.cr` | Round trips through `git upload-pack`/`receive-pack` as programs, through `git daemon`, and through ssh (argument layout and quoting checked by a recording stand-in); ssh URL parsing |
| TRANSPORT-O05 | `transport_spec.cr` | HTTP credentials are requested after a 401 and retried; wrong ones fail; credentials are never sent to a redirect target on another origin |
| TRANSPORT-O06 | `transport_spec.cr` | Advertised ref names that are not valid refs are ignored |
| REMOTE-O08 | `remote_spec.cr` | A failed clone removes the directory it created, or empties the empty directory it was given, and never touches a non-empty one |
| PORCELAIN-O01 | `porcelain_spec.cr` | `rev_parse` equals `rev-parse --verify` for 29 expressions and fails where Git fails for 8 |
| PORCELAIN-O02 | `porcelain_spec.cr` | `rev_list` equals `rev-list` for `A..B`, `A...B`, `^A B`; `ahead_behind` equals `--left-right --count` |
| PORCELAIN-O03 | `porcelain_spec.cr` | Branch listing, delete, rename and tag delete leave refs, reflogs and config as Git does |
| PORCELAIN-O04 | `porcelain_spec.cr` | `pull` fast-forwards, refuses diverged history without merge mode, and merges with two parents |
| MAINT-O01 | `maintenance_spec.cr` | `repack` keeps exactly the `rev-list --objects --all --reflog --indexed-objects` set in one pack; only unreachable objects stay loose |
| MAINT-O02 | `maintenance_spec.cr` | `refs.pack` writes `packed-refs` byte-identical to `git pack-refs --all` and prunes the same loose files |
| DIFF-O01 | `inspection_spec.cr` | `diff_trees` equals `diff-tree -r` raw and `--name-status` output (A/D/M/T, file/directory and symlink transitions, submodules, root diffs, path limits) and `-M100%` renames, under SHA-1 and SHA-256 |
| FSCK-O01 | `inspection_spec.cr` | `fsck` reports the unreachable set of `git fsck --unreachable`, a corrupt loose object and a missing reachable tree |
| PATCH (23 examples) | `patch_spec.cr` | `diff` and `commit_patch` text equals `git diff --no-color` (`--cached`, `a b`, `rev`, `show --format=`) byte for byte: every change kind, binary and invalid UTF-8 content, symlinks, gitlinks, quoted paths, context and `abbrev` settings, function-name headers, files of thousands of lines, the indent heuristic on and off, and a random-edit fuzz |
| STAGE (31 examples) | `stage_remove_spec.cr` | `stage` and `remove` leave `ls-files -s`, `status --porcelain` and the worktree as `git add -A`/`-u` and `git rm [--cached] [-f] [-r]` do, including conflicts, ignored and unmatched paths and every rm refusal |
| LEASE-O01..O12 | `push_lease_spec.cr` | `push(lease:)` updates and rejects (`stale info`) remote refs as `git push --force-with-lease[=ref[:expect]]` does, for tracking and explicit expectations, deletes, atomic pushes and transports |
| RL-01..RL-13 | `workflow_reflog_spec.cr` | HEAD, ORIG_HEAD, branch reflogs and branch config after `switch` (`-c`, `--detach`, guess), branch creation under each `branch.autoSetupMerge`, `reset`, fast-forward and merge commits, `merge --continue`, `commit --amend` and `rebase` equal Git's byte for byte |
| PORCELAIN-O05 | `porcelain_spec.cr` | `log` in each `History::Order` equals `rev-list`, `--date-order` and `--topo-order`, including a merge whose first parent is newer and clock skew |
| NA-01..NA-08 | `non_ascii_spec.cr` | Non-ASCII identities, messages, branch names, ignore patterns and ref names, and commits that are not UTF-8 (declared and undeclared encodings), read and copied as Git does |
| WS-01..WS-05 | `worktree_stat_spec.cr` | Status trusts index stat data like Git (racily clean files, restored mtimes, mode changes) and reports submodules and nested repositories as `git status` does |

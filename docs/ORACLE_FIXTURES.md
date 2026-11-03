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

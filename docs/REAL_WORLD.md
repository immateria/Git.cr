# Real repositories

The specs compare the library with Git 2.47.3 on small fixtures written for
each behaviour. `bench/realworld.cr` checks the same library against Git on
clones of real repositories instead, where history, names, sizes and
configuration are whatever their authors made them. It compares every answer
and times both sides.

## Running it

```bash
crystal build --release --no-debug bench/realworld.cr -o bin/realworld
```

```bash
git clone https://github.com/git/git /tmp/git-clone
```

```bash
GIT_ORACLE_BINARY=/usr/local/bin/git bin/realworld /tmp/git-clone --sample 30 --report report.md
```

`--checks` picks a subset (`objects,history,diffs,worktree,clone,index-pack,fsck`)
and `--https URL` adds a native clone over HTTPS. The worktree checks edit the
clone's files and restore them with `git reset --hard` and `git clean`; refs and
objects are not changed. The harness runs the `git` program; the library never
does.

| Check | Native | Compared with |
| --- | --- | --- |
| object headers | `object_header` for every object | `cat-file --batch-all-objects --batch-check` |
| object contents | `read_object` for every object, hash-verified | `cat-file --batch` (time only) |
| rev-list, log | `rev_list`, `log` in each `History::Order` | `rev-list`, `--date-order`, `--topo-order` |
| rev-parse | every ref, tag peels, sampled IDs, abbreviations, `HEAD:path`, `:path` | `rev-parse --verify` |
| merge-base | random commit pairs | `merge-base --all` |
| diff-tree, patches | newest and random commits | `diff-tree -r --name-status`; `diff -M100% --abbrev=12`, with the repository's `.gitattributes` and without |
| status, diff, stage | a clean checkout, then 40 deterministic edits | `status --porcelain -uall`, `diff`, `add -A` then `ls-files -s` and `diff --cached` |
| clone | `Repository.clone` over the local transport (and HTTPS) | `clone --no-local`: refs, index, clean status, `fsck --strict` |
| index-pack | the clone's pack into a new repository | `index-pack --rev-index`: `.idx` and `.rev` bytes |
| fsck | `fsck` | full `git fsck` |

Times for rev-parse, merge-base, diff-tree and patches include starting a `git`
process per item, so those ratios favour the library; the rest run one Git
command for the whole set.

## Results

Linux x86-64, 4 CPUs, Crystal 1.22.2 `--release`, Git 2.47.3. The ratio is the
library's time over Git's.

| Repository | Commits | Objects | Files | Notes |
| --- | ---: | ---: | ---: | --- |
| crystal-lang/shards | 598 | 4,378 | 146 | also cloned natively over HTTPS |
| crystal-lang/crystal | 17,182 | 164,240 | 2,749 | |
| git/git | 82,676 | 423,121 | 4,863 | a submodule, Latin-1 commits, 1,000+ tags, `diff=cpp` attributes |

### crystal-lang/shards

| Check | Result | Items | Native | Git | Ratio | Detail |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| object headers | pass | 4405 | 0.09s | 0.01s | 6.5x | 4405 objects |
| object contents | pass | 4405 | 0.1s | 0.04s | 2.5x | 4405 objects, 9 MiB |
| rev-list HEAD | pass | 598 | 0.01s | 0.01s | 1.1x | 598 commits |
| log (default) | pass | 598 | 0.03s | 0.01s | 2.4x | 598 commits |
| log --date-order | pass | 598 | 0.04s | 0.01s | 4.5x | 598 commits |
| log --topo-order | pass | 598 | 0.04s | 0.01s | 4.1x | 598 commits |
| rev-parse | pass | 472 | 0.14s | 1.74s | 0.1x | 472 expressions |
| merge-base | pass | 50 | 0.25s | 0.25s | 1.0x | 50 pairs |
| diff-tree | pass | 95 | 0.06s | 0.35s | 0.2x | 95 commits |
| patches no attributes | pass | 97 | 0.1s | 0.44s | 0.2x | 97 commits, 12505 patch lines |
| patches with .gitattributes | pass | 94 | 0.11s | 0.46s | 0.2x | 94 commits, 12946 patch lines |
| clean status | pass | 146 | 0.0s | 0.0s | 0.9x | worktree and index clean |
| dirty status | pass | 34 | 0.01s | 0.0s | 1.0x | 34 entries |
| worktree diff | pass | 1054 | 0.01s | 0.01s | 0.8x | 1054 lines |
| stage | pass | 143 | 0.02s | 0.01s | 3.0x | 143 index entries, diff --cached equal |
| clone (local) | pass | 4251 | 0.43s | 0.18s | 2.4x | 4251 objects; refs, index, status and fsck --strict agree |
| clone (https) | pass | 57 | 1.51s | 0.74s | 2.0x | 57 refs agree, clean checkout |
| index-pack | pass | 4378 | 0.2s | 0.07s | 2.8x | 4378 objects; .idx and .rev byte-identical |
| fsck | pass | 4405 | 0.12s | 0.08s | 1.4x | 4405 objects, 27 unreachable |

### crystal-lang/crystal

| Check | Result | Items | Native | Git | Ratio | Detail |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| object headers | pass | 164266 | 2.44s | 0.35s | 7.0x | 164266 objects |
| object contents | pass | 164266 | 12.47s | 3.79s | 3.3x | 164266 objects, 1134 MiB |
| rev-list HEAD | pass | 17182 | 0.39s | 0.3s | 1.3x | 17182 commits |
| log (default) | pass | 17182 | 0.78s | 0.28s | 2.8x | 17182 commits |
| log --date-order | pass | 17182 | 0.77s | 0.15s | 5.1x | 17182 commits |
| log --topo-order | pass | 17182 | 0.76s | 0.16s | 4.8x | 17182 commits |
| rev-parse | pass | 804 | 0.79s | 8.93s | 0.1x | 804 expressions |
| merge-base | pass | 40 | 5.42s | 2.38s | 2.3x | 40 pairs |
| diff-tree | pass | 80 | 0.09s | 1.01s | 0.1x | 80 commits |
| patches no attributes | pass | 80 | 0.19s | 0.96s | 0.2x | 80 commits, 9068 patch lines |
| patches with .gitattributes | pass | 80 | 0.22s | 1.28s | 0.2x | 80 commits, 16126 patch lines |
| clean status | pass | 2749 | 0.06s | 0.02s | 2.8x | worktree and index clean |
| dirty status | pass | 34 | 0.05s | 0.03s | 1.8x | 34 entries |
| worktree diff | pass | 2475 | 0.04s | 0.03s | 1.5x | 2475 lines |
| stage | pass | 2746 | 0.09s | 0.03s | 3.2x | 2746 index entries, diff --cached equal |
| clone (local) | pass | 162643 | 23.05s | 5.81s | 4.0x | 162643 objects; refs, index, status and fsck --strict agree |
| index-pack | pass | 164240 | 10.07s | 3.77s | 2.7x | 164240 objects; .idx and .rev byte-identical |
| fsck | pass | 164266 | 15.72s | 7.31s | 2.2x | 164266 objects, 26 unreachable |

### git/git

| Check | Result | Items | Native | Git | Ratio | Detail |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| object headers | pass | 423148 | 4.53s | 1.03s | 4.4x | 423148 objects (warm cache; see below) |
| object contents | pass | 423148 | 98.84s | 50.36s | 2.0x | 423148 objects, 7986 MiB (warm cache) |
| rev-list HEAD | pass | 82676 | 1.78s | 1.32s | 1.3x | 82676 commits |
| log (default) | pass | 82676 | 3.79s | 1.35s | 2.8x | 82676 commits |
| log --date-order | pass | 82676 | 3.57s | 0.96s | 3.7x | 82676 commits |
| log --topo-order | pass | 82676 | 3.63s | 0.93s | 3.9x | 82676 commits |
| rev-parse | pass | 2302 | 1.27s | 15.69s | 0.1x | 2302 expressions |
| merge-base | pass | 30 | 28.44s | 13.56s | 2.1x | 30 pairs |
| diff-tree | pass | 59 | 0.13s | 0.43s | 0.3x | 59 commits |
| patches no attributes | pass | 60 | 0.27s | 0.63s | 0.4x | 60 commits, 10300 patch lines |
| patches with .gitattributes | differs | 60 | 0.34s | 0.59s | 0.6x | 4/60 differ only in hunk-header function names: git/git sets `*.c diff=cpp`, whose driver is not implemented |
| clean status | pass | 4863 | 0.37s | 0.02s | 23.3x | worktree and index clean |
| dirty status | pass | 34 | 0.07s | 0.02s | 4.0x | 34 entries |
| worktree diff | pass | 4428 | 0.04s | 0.02s | 2.1x | 4428 lines |
| stage | pass | 4860 | 0.1s | 0.03s | 3.7x | 4860 index entries, diff --cached equal |
| clone (local) | pass | 411345 | 109.14s | 28.32s | 3.9x | 411345 objects; refs, index, status and fsck --strict agree |
| index-pack | pass | 423121 | 28.69s | 18.1s | 1.6x | 423121 objects; .idx and .rev byte-identical |
| fsck | pass | 423148 | 178.82s | 49.66s | 3.6x | 423148 objects, 27 unreachable |

The object rows come from a second run with the pack in the page cache; in
the first, after a container restart, Git's header pass read the 330 MB pack
from disk. Clean status includes `staged_changes`, which walks the whole HEAD
tree where Git uses the index's cache-tree extension; the worktree half alone
is the dirty-status row.

## What it found

None of these showed up in the fixture specs. Each is fixed, with a spec that
reproduces it.

- **Character offsets used as byte offsets.** `String#index` counts
  characters and `byte_slice` counts bytes; they agree only while the text
  before the match is ASCII. A commit by "Johannes Müller" lost its committer
  time, so history came out of order, and its message was split one byte off:
  log subjects were wrong and cherry-pick, revert, rebase and amend wrote the
  damaged message into new commits. The same mix broke config keys for
  non-ASCII branch names, ref advertisements, `A..B` ranges, refspecs and
  ignore patterns (NA-01 to NA-06).
- **Commits that are not UTF-8.** `read_commit` refused them, so `log` failed
  on git/git. Declared encodings are now shown as UTF-8 and undeclared bytes
  kept, as Git does (NA-07, NA-08).
- **`--topo-order`.** What the library called topological order was Git's
  `--date-order`; Git's `--topo-order` keeps each line of history together
  (PORCELAIN-O05).
- **Clone tags.** A full clone skipped tags that no branch reaches; `git
  clone` takes every advertised tag.
- **Submodules.** Status reported every submodule as unsupported, so a
  repository with one never looked clean (WS-05).
- **Budgets real repositories exceed.** `merge`, `fast_forward` and `pull` walked
  each side's whole history against a 16,384-commit budget, so they failed on
  any longer history; merge-base now paints down from both tips as Git does.
  Status read every tracked file against an 8 MB scan budget, so it failed on
  any larger worktree; it now trusts the index's stat data (WS-01 to WS-04).

The same runs drove the performance work: one `pread` handle per pack and a
single CRC-checked read per entry (instead of two opens and two reads), packs
before loose objects, cached delta types, Git's stat cache for status,
paint-down merge-base, a cached `packed-refs` parse and faster ignore matching.
On crystal-lang/crystal, object headers went from 36x to 7x Git's time, status
from 22x to under 3x, merge-base from 12x to about 2x and clone from 8x to 4x.

## Remaining differences

- Hunk headers use Git's default function-name rule; `.gitattributes` language
  drivers (`*.c diff=cpp`) are not applied. git/git shows this in a few patches
  when its attributes are used.
- IDs in `index` lines are abbreviated to at least 7 digits; Git lengthens its
  default with the object count. The harness passes `--abbrev=12` to both.
- Renames are exact only; the harness asks Git for `-M100%`.
- Git's wildmatch compares bytes, so `?` and `[...]` never match a multibyte
  character; the library matches characters.
- Indexes the library writes carry no stat data, so the first status after a
  native clone or checkout hashes every file.
- Reading every object is still several times slower than Git's C with
  memory-mapped packs.

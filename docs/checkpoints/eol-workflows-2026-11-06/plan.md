# EOL workflow integration implementation plan

> Agentic workers: use the recorded design and task brief; implement with focused red/green verification and task review before integration.

Goal: complete native EOL handling in merge, replay and stash while preserving recovery safety.
Architecture: one shared foundation, three isolated workflow worktrees, sequential cherry-pick integration.
Tech stack: Crystal >=1.13.0, Git 2.47.3 oracle, no production Git subprocesses.
Spec: /workspace/work/git-eol-workflows/design.md

## Global constraints

All Binding contract and Shared interfaces sections of design.md are binding. Verification versions: Crystal 1.13.0 and 1.22.2; oracle /workspace/toolchains/git-2.47.3/bin/git asserted exactly git version 2.47.3. Preserve canonical index/object identities and raw publication/recovery identities. Public return values remain compatible. Isolated caches, no force push, no production Git invocation.

## Review focus

Conflict-marker .gitattributes and relocated output paths must select the final attribute rules (foundation + merge/replay tests).
EOL-only concurrent changes must fail raw publication/recovery guards (all three streams).
Rebase/abort retry must recognize only owned materialized bytes (replay + shared receipt tests).
Stash selected-path and third-parent attribute sources must match their operation phase (stash tests).
Expansion budgets and warning callbacks must fail before publication without false-clean stats or unrelated path validation (foundation + stash tests).

## Task 1: shared foundation
- [ ] Write helper/receipt/clean_only failing regression specs.
- [ ] Implement the exact shared interfaces from design.md and raw receipt encoding.
- [ ] Run focused support, checkout/reset/recovery tests on both versions; format and diff check.
- [ ] Commit task-owned files and report commit range, checks, concerns.
- [ ] Task review (spec compliance + quality), fix confirmed issues, integrate foundation.

## Task 2: merge stream
- [ ] After foundation is available, create isolated merge worktree.
- [ ] Add SHA1/SHA256 failing EOL merge/fast-forward/abort/continue/relocation/conflict tests using pinned oracle.
- [ ] Thread config; keep raw observations; materialize final plan writes/abort goals with common helpers; forward pull config.
- [ ] Run focused EOL + existing merge/recovery/pull cases and format/diff checks.
- [ ] Commit task-owned paths, report evidence; task review and fixes.

## Task 3: replay stream (parallel with Tasks 2 and 4)
- [ ] Add failing cherry-pick/revert/rebase/continue/skip/abort/retry EOL specs and config tests.
- [ ] Thread config across facades/private calls; use final result attrs and raw receipt/observation identities.
- [ ] Verify initial onto and outer abort exact raw materializations, incomplete retries, bytes/entry budgets and callback races.
- [ ] Run focused EOL + existing sequencer/rebase/recovery tests and format/diff checks.
- [ ] Commit task-owned paths, report evidence; task review and fixes.

## Task 4: stash stream (parallel, tracked apply depends on replay)
- [ ] Add failing save/apply/pop/index and capture/cleanup source/selection EOL specs with pinned oracle.
- [ ] Split canonical captures and raw observations; thread config/warning; integrate cleanup conversion and third-parent outputs.
- [ ] Verify clean no-op, safecrlf changed/new captures, callback safety, expansion budgets and raw overwrite guards.
- [ ] Coordinate replay integration for tracked apply; test complete stash after dependency lands.
- [ ] Commit task-owned paths, report evidence; task review and fixes.

## Task 5: sequential integration and closure
- [ ] Cherry-pick clean reviewed commits onto integration branch one stream at a time (merge, replay, stash; replay before stash final gate).
- [ ] Resolve conflicts by contract, run relevant combined tests after each.
- [ ] Update documentation and remaining gaps based on final behavior.
- [ ] Full specs + formatting on both compilers; measure actual spec inventory; fresh consumers with no Git on PATH.
- [ ] Final independent adversarial review(s), fix substantive findings, rerun affected gates and verify final source fingerprint.
- [ ] Preserve isolated worktrees and report resulting branch/commits, verification and any actual limitations. Publishing is a separate user action unless explicitly requested for this feature.

# EOL workflows checkpoint — 2026-11-06

This branch preserves unfinished work. It combines the shared conversion foundation, merge/fast-forward, replay (cherry-pick/revert/rebase), and stash implementations, including the latest replay fixes and the unverified stash review fix. It is not a release or a claim that the combined feature passes.

No tests were run to produce this checkpoint. The user stopped background work after the container accumulated roughly 32,000 orphan Git maintenance zombies. Further test/compiler runs remain paused. Source content and index checksums were checked when preparing the checkpoint.

## Saved branches and commits

| Work | Branch | Saved commit |
| --- | --- | --- |
| Previously completed EOL feature | recovery-eol | 1ff359874fc931f33d53aa5fb22fc4913e1fa62b |
| Shared foundation | feature/eol-workflow-foundation | 8d6309702ea47693f837d4be44fc090f43d49f78 |
| Merge / fast-forward | feature/eol-merge | 5804533b7b81f81e8a336558aac087fb0ee7c29a |
| Replay, including review fixes | feature/eol-replay | 87fe5926e55bb70b44e1dd41389b6d8f0cbf653c |
| Stash, including pending review fix | feature/eol-stash | eb47d749b90aa51f614beee03f36ef8f21726f6e |
| Reviewed foundation + merge integration | feature/eol-workflows | ad1113acfa9abddf3ad7aec551d6696b415ffeb5 |

The checkpoint commit retains the component history as parents. Source changes from the independent streams were combined by their committed path/OID maps; there was no overlapping stream ownership. Existing development worktrees and branch tips were kept.

## Review and verification state

- Foundation: task review approved; historical report records 138 focused examples passing on both compilers.
- Merge: task review approved; historical report records 483 related examples passing on both compilers.
- Replay: initial review found three issues. Additive fix commit 87fe592 follows reviewed commit d9e2b57459c379200952f6808aea321773ab3179. Its report records 345 focused examples passing on both compilers. The same reviewer still needs to recheck this fix range.
- Stash: initial task commit 1ffd545bcbdafd7c10e04e4d7459225dbcd7671b had 156 focused examples passing on both compilers. Review then reproduced an attribute-source mutation through the warning callback: six regression cases, four failures, two passing controls. Commit eb47d74 saves the proposed fix and regressions. Its green run has NOT completed and its fix has NOT been re-reviewed.
- The combined checkpoint has NOT been compiled or tested. Final integration, whole-branch adversarial review, downstream consumer checks, full suites, and feature documentation updates are outstanding.

The earlier completed recovery-eol feature had 1,254 examples passing on both compiler versions before this workflow extension. Do not treat that result as evidence for this checkpoint.

## Resume

1. Use a fresh or repaired execution environment. Do not restart test matrices in the exhausted container. Keep the previous environment's uncommitted scratch artifacts until the checkpoint has been verified remotely.
2. Install the pinned lanes: Crystal 1.13.0 and 1.22.2, Git 2.47.3. The project's oracle requires the pinned Git version.
3. Read docs/checkpoints/eol-workflows-2026-11-06/design.md, plan.md, task reports, and reviews. The chronological progress ledger contains superseded entries; this file is the current checkpoint summary.
4. Run the stash fix regressions and relevant stash suite, then have the original stash reviewer recheck 1ffd545..eb47d74. Have the original replay reviewer recheck d9e2b57..87fe592. Do not assume the fixes are approved.
5. Validate the combined source on both compiler lanes, run the downstream consumer, update the README/parity notes to match actual support, and obtain a fresh whole-branch adversarial review. Fix findings and recheck before claiming completion.

Disable Git automatic maintenance during fixture-heavy validation. The archived git-oracle-stable wrapper shows the temporary mitigation; adjust its absolute Git path for the new environment. Set GC_MARKERS=1, GC_NPROCS=1, and CRYSTAL_WORKERS=1 after sourcing any toolchain environment, and serialize heavy validation. Preserve Git config introspection behavior and exact oracle version checks.

## Recovery material

The docs/checkpoints/eol-workflows-2026-11-06 directory contains the design, plan, task briefs/reports, immutable review packages, review findings, consumer sources, and source provenance. Scratch repositories, binaries, toolchains, caches, process-reaping experiments, and credentials are intentionally excluded.

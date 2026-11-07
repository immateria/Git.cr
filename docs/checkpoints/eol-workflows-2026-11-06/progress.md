# SDD ledger — plan: /workspace/work/git-eol-workflows/plan.md

Base: 1ff359874fc931f33d53aa5fb22fc4913e1fa62b (recovery-eol, already pushed).
Integration: /workspace/work/git-eol-workflows/integration, feature/eol-workflows.
Recon completed read-only for merge, replay and stash; pinned Git2.47.3 verified. Baseline full suite running.

Ruling: user chose and authorized the proposed shared-contract/three-worktree architecture with "do that"; do not repeat design approval questions. Exact helper signatures and routine choices recorded in design.md.
Ruling: worktrees and transient plan artifacts live under /workspace/work/git-eol-workflows to keep source checkout clean and honor workspace scratch guidance. No native worktree tool is available; use git worktree fallback.
Ruling: cloud skill helper scripts are not local executables; maintain equivalent briefs/reports/ledger/review packages directly here. No repeated checkpoint commits of plans are needed; keep feature commits limited to source/tests/docs.

## Preflight conflict scan
| Tasks | Shared interface/file | Finding and ruling |
| --- | --- | --- |
| Foundation/Merge | Conversion helpers, Recovery.encode, hard_reset clean_only | Foundation owns helpers/receipts/reset; merge consumes exact signatures, does not edit shared files without coordination. |
| Foundation/Replay | Planned attrs/materialize/raw_states + receipt semantics | Replay consumes helpers; rebase-specific recovery provenance remains replay-owned. Coordinate needed shared extensions first. |
| Foundation/Stash | materialize + planned attrs | Stash uses helpers where apt; capture/selected cleanup logic stays stash-owned. |
| Merge/Replay | Merge.plan_files + recovery encoding | Both stay canonical until after relocation; parent owns shared implementation, callers own config/raw guards. |
| Replay/Stash | sequencer_start(config:) for stash apply | Replay adds optional config keyword. Stash codes in parallel; final tracked apply tests depend on replay integration. No overlapping source ownership. |
| Merge/Stash | None beyond shared helpers | No file overlap; same output/guard contract. |
| Each task | Brief tests vs implementation/files | Testable deliverables and exclusive source ownership recorded. Full suites/consumers/reviews delegated only after integration. |

Tasks 1–5 pending. No new feature commits or pushes yet.

Baseline: 1,254 examples passed, Crystal1.22.2/Git2.47.3 at immutable1ff3598.
Builder check identified stash/replay seam gap; resolved with private prepare_worktree hook returning remaining output budget before publication. Pinned oracle confirms third-parent attrs apply ONLY to later untracked outputs. Added unmapped-worktree fallback to for_index contract (explicit deletions still block). Foundation ownership includes the two converter source-policy files.

Builder verdict: READY; no remaining contract blockers. All workflow branches start at1ff3598; foundation feature/eol-workflow-foundation active, merge feature/eol-merge active, replay feature/eol-replay active, stash feature/eol-stash active. Four worktrees isolated under work root. Task reports pending.
Ruling: replay may implement operation-bound two-map raw rebase recovery provenance in replay-owned metadata; combined bytes/counts bounded by existing budgets. This avoids shared receipt format expansion. Never recompute retry ownership from current config or capture arbitrary observed dirty files as owned.
Ruling: consumers of pending foundation can commit task-owned WIP locally, then rebase onto foundation; task-review base becomes foundation commit. Stash eventually rebases onto reviewed replay/integration before final tracked apply gate. No new branch pushed without a task-specific user request.

Task2 red evidence: 18 new examples fail on base (8 output mismatches, 10 dirty-CRLF refusals), path merge/logs/merge-red.log. Preexisting text marker alignment differs for partial multiline conflicts; stream tests use supported one-line conflicts and keep exact oracle comparison. Full ort marker alignment is not part of EOL scope; report limit at final review.
Task1 interface helper signatures accepted by implementer, red helper/receipt/FF specs in progress. Task3 rebase-owned bounded dual-map provenance design approved. Task4 phased attribute oracle evidence retained in recon-stash.
Compatibility worker preparing native cross-workflow consumers under consumer/; no extra full baselines.

Task1 provisional helper commit e2195ca (134 focused examples pass on1.13+1.22,19newsupportcases); consumers instructed rebase own WIP onto it. Task1 followup pending before final taskreview.
Ruling: stash selected keep_index needs partial selected-index attr overlay with unselected WT-first/index fallback. Approved worktree_index_fallback optin only alongside blobmap+WTfallback, explicitnil remains authoritative. for_index false preserves plannedindex snapshot; foundation owns sourcefiles/tests. Documented with pinned stash oracle evidence. No unsafe separate attribute readers in stash.
Task4 initial red:10examples6failures2errors, canonical/raw capture and cleanup failures. Local stash WIP cb0aea0 before foundation rebase. Task3 config/hook implementation active; rebase persistent raw provenance active.

Task1 DONE pending taskreview: complete range1ff3598..8d63097 (e2195ca+8d63097),138focusedpassboth; report task-1-report.md and immutable review package reviews/task-1.diff.md, foundation_review active. Worker consumers rebased onto8d63097.
Task2 provisional commits a3d271c,5804533 after8d63097;50newmerge examples pass1.22, related suitesboth lanes running. Report pending.
Task3 provisional tip e8df1a9 after8d63097, commits714b64b,b977aba,e8df1a9;102focusedpass1.22 beforenewattrs examples. Sentdependencyto stash. Exactfinalreviewrange pending.
Task4 capture36green1.22/min pending; apply16cases await replayprovisionalbase. Indexsnapshot freeze added beforecapture toreject warningcallback indexmutations (new callback boundary), no refpublication on mismatch; dependency sourceflag supportssecureselectedkeep_indexfallback.

Task1: complete (commits1ff3598..8d63097,reviewclean). Foundation spec✅/qualityApproved at reviews/task-1-review.md. Integrated as9b75bd2+ffca951 on feature/eol-workflows (treeequivalent tosource8d63097).
Task2: DONE pendingreview,483relatedexamplespassbothlanes+50newEOL, reporttask-2-report.md; merge_task_review active with reviews/task-2.diff.md (8d63097..5804533).
Task3:114focusedlatestgreennewattrs; extendedrecovery/mutatedindexcallbacks/budgethookcases active beforefinalreport.
Task4:36capturegreen,142combinedstash old+new onprovisionalreplay tip; finalapplysuite awaits latestreplay andreview. Callbackindexfreezeandworktreefallbacksourcefix included.

Task2: complete (commits8d63097..5804533,reviewclean). Spec✅/qualityApproved at reviews/task-2-review.md,483relatedtests bothcompilerlanes. Integrateda3d271c+5804533 bysequentialcherry-pick; integrated tree byte-identicalto tested5804533 verifiedgitdiffexit0.
Ruling: exacttreeequivalence reuses previously runrelatedsuite evidence rather than duplicating same tests; finalcombinedbothcompilerfullsuite remainsrequired.
Task3 latest327focusedexamplespassboth;8additionalpartialCRLF/provenancecases pending beforefinalcommit/report. Task4 latest150passboth,final154snapshot/dep update pending. No workflowcode conflicts so far.

Task3 DONE pendingreview: final singlecommitd9e2b57459c379200952f6808aea321773ab3179 atop8d63097;335distinctexamplespassboth (327matrix+18partialextension overlapping10base), report task-3-report.md, immutable reviews/task-3.diff.md; replay_task_review active.
Task4 finaltaskbase d9e2b57 after rebase;154focusedpassboth beforelatestBOMcharacterization. Parent requested pinnedBOMsourceprobe; resultNO GAP: untracked thirdparentattrBOM remainsblobpolicy anduLF (notfileBOMstripping), matchingfor_index. Added narrowregression with no productionchange. Finalstashreport/commitpending.

Task3 reviewNeedsfixes/spec❌; source d9e2b57 NOT integrated. OpenP1bothreceipt+markerloss resetsretryauthority; P2onto expansionaftermetadata/ORIG_HEAD; P2combinedpathcount absent. Exactreport reviews/task-3-review.md; fixround1/5 dispatchedoriginalimplementer, addcommitsno rewrite ofreviewedSHA.
Ruling: combinedlimit is distinctpathunion<=max_entries, atmost2rawrecords/path (<=2*max_entries Int64); preservespriorpublicn-filecapacity. Adddisjointunionfail +overlapvariantpass tests. Spec/briefclarified and reviewer notified. P1+ontoP2 acceptedmandatory.
Task4 DONE on1ffd545 atopd9e2b57;156focusedpassboth, reporttask-4-report.md, task4immutablepackage prepared, stash_task_review active. Awaitreplayfixhandoff beforefinalstashrebase andintegration.

Task4 reviewinprogress confirmedP2callback/sourcecaptureinconsistency (bothphasecacheandlateruntrackedattrsnapshot); finalreportpendingSHA256confirmation. Exactcase: callbackchangesuntrackedattrs oldtextCRLF->new-text beforeuntrackedcapture; savedattrsnewbutu normalizedold, raworiginalremoved andapplyLF. Parentnotifiedimplementerawaitfinalreport/redtest; likelydeferuserwarningdeliveryuntilsnapshotscomplete, retainexistingraw/indexguards. Reviewerdisprovedraw==canonicalcleanupcandidateagainstpinnedGit4forms; notafinding.

Resourceincident: PID1is tail, cannotreap32,366orphanGitmaintenancezombies; pids.current~32432 nearancestorlimit, memory2.8GiB/16GiB noOOM. Concurrentreplaymatrices hadforkEAGAIN errors inunchangedfixtures; notacceptedvalidation. NOproductionfixforenvironment.
Mitigationverified: GC_MARKERS=1 GC_NPROCS=1 CRYSTAL_WORKERS=1 AFTERsourceenv; GIT_ORACLE_BINARY=/workspace/work/git-eol-workflows/git-oracle-stable (pinned2.47.3 exec wrapper disablesmaintenance.auto/gc.auto/packthreads exceptconfigqueriespassunchanged); allheavyvalidationmust flock validation.lock, serialize. Tenfixturecommits pids32432->32432 andconfigintrospectionunchanged. Existingzombiesnotkilled/environmentnotrestarted. Compatnotifiedgatesmustserial.
Task3 red20examples10failuresbothversions for3reviewissues, thenreview20greenlatest; first345minimumfixmatrixpassed withlowthreads/localmaintenancewrapper;latestforkerrorsinvalid;lockedlatestmatrixactivewithsharedwrapper.
Task4 red6examples4failures0errorsunderstablemitigation,2controls pass, sourcecapturedlater+outsideselectedmutationscaptured; fixinprogressstash-only.

## User-requested process stop

All agents are completed/idle. Process inventory confirms no live Git, Crystal compiler, spec, maintenance, or cleanup-helper jobs. Only container infrastructure and the inventory command are live. Approximately 32,381 zombies remain, owned by the unreaping PID 1 (tail); these have already exited and cannot be killed. PID 1 remains running in sleeping state. No further validation is authorized to start until process cleanup is resolved. Replay additive fix commit 87fe5926e55bb70b44e1dd41389b6d8f0cbf653c is saved and awaits scoped re-review. Stash review fix/regressions remain preserved uncommitted; green verification has not run. Integration remains at ad1113a. All feature work is preserved.

## Requested checkpoint

User authorized commit/push of current incomplete work. Stash WIP fix/regressions saved in eb47d749b90aa51f614beee03f36ef8f21726f6e. No tests resumed. Preparing a combined checkpoint branch plus separate stream refs and recovery notes; combined source remains unverified.

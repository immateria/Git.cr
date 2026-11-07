# Native EOL workflow consumer

This standalone program requires only `git` and the standard library. Its local
dependency points at `../integration`; each fixture is a new ordinary repository
under `repos/`, separate from the linked source checkout.

For both SHA-1 and SHA-256, it checks:

- Fast-forward and divergent three-way merge of disjoint edits.
- Cherry-pick and revert of disjoint edits.
- Two-commit rebase onto another branch, using explicit `onto:`.
- Stash push, apply and pop with staged, unstaged and untracked CRLF content.

Assertions cover raw CRLF worktree bytes, canonical index/object IDs, saved stash
blobs, history parents, clean states and stash retention/removal. Workflow calls
use the additive `config:` keyword; stash capture also uses `warning:`.

Run only after the implementation branches have landed in `integration`:

```sh
source /workspace/toolchains/env.sh
CRYSTAL_WORKERS=2 \
CRYSTAL_CACHE_DIR=/workspace/work/git-eol-workflows/cache-consumer-1.13.0 \
  /workspace/toolchains/crystal-1.13.0/bin/crystal build main.cr --error-trace -o consumer-1.13.0
PATH=/nonexistent ./consumer-1.13.0

CRYSTAL_WORKERS=2 \
CRYSTAL_CACHE_DIR=/workspace/work/git-eol-workflows/cache-consumer-1.22.2 \
  /workspace/toolchains/crystal-1.22.2/bin/crystal build main.cr --error-trace -o consumer-1.22.2
PATH=/nonexistent ./consumer-1.22.2
```

No Git executable is available through `PATH` during either runtime check.

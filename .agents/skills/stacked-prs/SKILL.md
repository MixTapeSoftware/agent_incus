---
name: stacked-prs
description: Use when a change is too large for one focused PR, when asked to split or stack PRs, or when creating, updating, or merging a chain of dependent PRs.
---

# Stacked PRs

A stack is a chain of small PRs where each branch builds on the one below it. Reviewers see one focused change at a time, and lower layers can merge while upper layers are still in review.

## When to stack

Split a change when it mixes independent concerns or is too large to review carefully in one sitting (as a rough guide, more than about 400 changed lines). Each layer should be one coherent step that builds and passes the repository's checks on its own, for example: setup or refactor first, then the feature, then its follow-up cleanup. Do not split a change only to shrink it; a layer that cannot stand alone belongs with its neighbour.

## Create the stack

1. Branch the first layer from the default branch, commit, push, and open its PR against the default branch:
   ```bash
   git switch -c <layer-1> main
   git push -u origin <layer-1>
   gh pr create --base main --head <layer-1>
   ```
2. Branch each next layer from the layer below it, and open its PR with the layer below as the base, so the PR shows only that layer's commits:
   ```bash
   git switch -c <layer-2> <layer-1>
   git push -u origin <layer-2>
   gh pr create --base <layer-1> --head <layer-2>
   ```
3. In every PR description, list the whole stack in order, mark the current PR, and state which PR it depends on. Keep this list current as layers merge.

### Splitting an existing large branch

Uncommit the work while keeping the changes, then commit it back in layers:

```bash
git switch <big-branch>
git reset --soft main       # uncommit, keep the changes
git restore --staged .      # unstage everything
```

Stage and commit the first layer's files, create that branch, then continue with the next layer on top. Push each layer and open its PR as above. Check that each layer passes the repository's checks before opening it.

## Update a lower layer

After changing a layer, carry the change up through every layer above it, in order from the bottom:

```bash
git switch <layer-2>
git rebase <layer-1>
git push --force-with-lease
```

Repeat for each higher layer against its new parent. Merging the parent in (`git merge <layer-1>`) works too and avoids force pushes, at the cost of merge commits. Never force push a branch someone else is also pushing to.

## Merge the stack

Merge from the bottom up. When a layer's branch is deleted after merging, GitHub retargets the next PR to the default branch.

- **Merge commits:** merge each lower PR with a regular merge commit. The next PR's commits stay recognisable, so it shows only its own changes after retargeting.
- **Squash or rebase merges:** these rewrite the lower layer's commits, so the next branch still carries the originals. After each lower PR merges, rebase the next layer onto the default branch, dropping the merged commits, then retarget and force push:
  ```bash
  git fetch origin
  git rebase --onto origin/main <old-layer-1-tip> <layer-2>
  gh pr edit <layer-2-pr> --base main
  git push --force-with-lease
  ```
  Record `<old-layer-1-tip>` (`git rev-parse <layer-1>`) before the lower branch is deleted.

Do not merge an upper PR into its parent unless you intend to combine those layers into a single merge to the default branch.

## Pitfalls

- A PR left targeting the default branch instead of its parent shows every lower layer's commits too. Check each PR's base.
- After one layer merges, the default branch has only part of the change, and teammates may wonder where the rest went. The stack list in every description tells them.
- Review feedback on a lower layer changes everything above it. Address lower layers first, then update the stack upward.

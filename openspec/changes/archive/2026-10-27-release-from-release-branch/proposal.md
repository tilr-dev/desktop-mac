# Release from a release branch, specification checks on main

## Why
The repository moved to one integration branch, main, which agents change with every merge, so it cannot define what a release contains. A release branch fixes the set of features for one Tilr release. The development branch no longer exists, so the specification check rules that name it describe a branch that pull requests can no longer target.

## What Changes
- The Release workflow runs only from a release/X.Y branch: a first job without keys refuses any other ref, and the signing and release environments accept only release/* as well.
- The specification change authorization requirement names main as the target of pull requests and its trusted workflow, and is renamed accordingly.
- The merge readiness diagnostics compare against main and tell the author to merge main; because a modification cannot rename the conflict scenario, the requirement is removed and added again as Specification merge readiness diagnostics on main.
- The shared checker scripts are downloaded from one immutable gitpm commit instead of the moving gitpm main, so a checker change in gitpm cannot fail this check before the workflow pins it.

## Impact
- Release and specification workflows, the release workflow contract test, PRODUCTION.md, CLAUDE.md and gitpm.pin.
- Modify Release from CI in release-publishing.
- Rename and modify Specification change authorization on dev, remove Specification merge readiness diagnostics and add Specification merge readiness diagnostics on main in development.

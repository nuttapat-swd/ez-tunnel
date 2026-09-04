---
name: implement-ticket
description: Implement a ready GitHub issue end-to-end in the EZ Tunnel repository, or shortlist suitable unblocked issues for the user to choose when no ticket is specified.
---

# Implement an EZ Tunnel ticket

Use this skill for requests to select or implement a GitHub issue in this repository.

Follow `AGENTS.md`, `docs/agents/issue-tracker.md`, `docs/agents/triage-labels.md`, `docs/agents/domain.md`, `CONTEXT.md`, and every applicable ADR under `docs/adr/`. Treat superseded ADRs as historical context, not current constraints.

## Language

Communicate with the user in Thai even when the request, issue, code comments, or source material is in English. Write questions requiring a decision, progress updates, and the final review package in Thai. Use English only for code, identifiers, commands, commit messages, and technical terms where English is clearer or follows repository conventions.

## Choose a ticket when none is specified

1. List open GitHub issues and inspect the complete body, comments, labels, dependencies, and linked work for plausible candidates.
2. Consider only issues labelled `ready-for-agent`. Exclude issues that are waiting on another issue or PR, carry `needs-info`, are assigned to `ready-for-human`, have an unresolved dependency, or otherwise cannot be completed safely now.
3. Present a compact shortlist to the user. For each issue include its number, title, a one- or two-sentence explanation of its user-visible outcome, and any notable scope or risk.
4. Recommend one issue and explain briefly why it is the best next item, considering value, readiness, dependency order, and implementation risk.
5. Ask the user to select a ticket. Do not begin implementation, create a branch, or mutate an issue until the user chooses.

If no eligible issue exists, report why the closest candidates are blocked instead of inventing work.

## Establish scope

For the selected ticket:

1. Read the complete issue and all comments again, including labels and linked dependencies.
2. Confirm internally that it is open, labelled `ready-for-agent`, unblocked, and sufficiently specified.
3. Read the domain context and applicable ADRs before changing code.
4. Inspect the current branch, working tree, merge-base, relevant code paths, and existing test seams. Preserve unrelated user changes.

Work autonomously from this point until the implementation is ready for the user's final review. Continue through routine implementation choices, validation, review findings, and fixes without waiting for confirmation.

The issue and its acceptance criteria authorize routine, reversible implementation decisions within the ticket. They do not authorize new dependencies, public API or schema changes, destructive migrations, secrets, production access, external communication, spending, deployment, merging, or other irreversible actions.

Ask the user only when:

- acceptance criteria conflict or essential behavior is unspecified;
- plausible choices would create materially different user-visible behavior;
- the work conflicts with an ADR or requires changing a public API or schema;
- a new dependency or any other action outside the authorization above is required;
- completion would expand beyond the ticket's stated scope; or
- validation cannot be made reliable after exhausting safe local approaches.

Do not pause for filenames, internal structure, test organization, minor refactors, or dependency-free implementation details.

## Implement with vertical TDD

Load and follow the available `tdd` Matt engineering skill. Work in vertical tracer bullets through the public behavior:

1. Add one focused behavioral test that fails for the missing behavior and run it to demonstrate red for the intended reason.
2. Add the smallest implementation that makes that behavior pass.
3. Refactor only while green.
4. Repeat with the next acceptance behavior until the ticket is covered.

Prefer existing public interfaces and testing seams. Avoid broad speculative refactors and mocks that merely restate implementation details. Run targeted tests throughout development.

## Validate and review

After implementation:

1. Run the repository's formatter, typecheck, lint, build, and full relevant test suite. If a standard check is unavailable, record the exact limitation and run the strongest reliable local substitute.
2. Determine the merge-base against the target branch.
3. Load and follow the available `scrutinize` Matt engineering skill against all changes since that merge-base, tracing the real execution path and checking whether a simpler solution would satisfy the issue.
4. Load and follow the available `code-review` Matt engineering skill against the same merge-base for both repository standards and issue/spec compliance.
5. Fix every blocker and major finding, add regression coverage where appropriate, then rerun affected validation and both reviews until no blocker or major finding remains.
6. Inspect the final diff for accidental files, secrets, unrelated changes, debug output, and formatting errors.

## Finish

Commit the complete implementation on the task branch using the repository's commit conventions. Do not merge, push, deploy, close the issue, or mutate production unless the user explicitly asks for that action.

Return only when the change is ready for final review. Write the review package in the user's language and include:

- outcome and user-visible behavior;
- commit SHA and changed files;
- an acceptance-criterion-to-evidence mapping;
- tests and checks run with their results;
- review findings found and fixed;
- remaining risks, assumptions, unavailable checks, and specific manual checks the user should perform.

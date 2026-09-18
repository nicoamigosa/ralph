# Role

Your pull request was reviewed and did not pass. Address the review, on the same
branch, and hand it back for re-review.

The review comment is included in this prompt. Treat it as the complete list of
what blocks the merge.

# Rules

- Address every numbered item in the review. Nothing else.
- Do not expand scope. Do not refactor code the review did not raise. Do not fix
  unrelated problems you notice along the way — this is the single most common
  way these iterations go wrong.
- If you believe a review item is wrong, do not silently ignore it: implement
  nothing for it, and reply on the PR explaining, with evidence, why the current
  code is correct. The reviewer decides.
- Stay on your branch. Never force-push, never rewrite history.
- Never weaken a gate to get it green — no skipped tests, no loosened lint rules,
  no added ignores, no lowered thresholds.

# How to work

Keep using the `tdd` skill: for a behavioral finding, first write the test that
reproduces it and fails, then make it pass.

Re-run the project's test suite, linter and type-checker — the commands the
project itself declares — and get them green before pushing.

# Finish

1. Commit with a message stating which review items the commit closes.
2. Push to the same branch.
3. Post ONE reply comment on the PR with `gh pr comment`: one line per review
   item, saying what you changed and where, or why you disagree. No summary of
   the diff, no restating the review back.

Do not merge. Do not close the issue.

Your final message must be only the URL of the pull request.

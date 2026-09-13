# Sprint 162 backend-overlay findings

| root | first cause | mechanism | status |
| --- | --- | --- | --- |
| package:cmd/compile/internal/abt | compiled package backend built a flattened temporary module, so cmd/go could not apply original-path internal-import policy | one library transpilation per package, with an original-path cmd/go overlay | fixed in current candidate |
| package:cmd/compile/internal/ssa | package has `*_test.s` companions | D3(b): cmd/go assembles the companions natively under the overlay | recorded disposition |

## Requests to other seams

The harness-owner seam must update its authenticated pin file (outside this
lane's allowed file list) after taking this commit:

```diff
--- a/tools/upstream-harness/backend-pin.tsv
+++ b/tools/upstream-harness/backend-pin.tsv
@@
-gotest_hook\t46013f13c92b9513e0e9b7ffc7a76ffb9fee81cefd7f48a9b40106ab7115fb8c
-package_verifier\ta384858c0dd3a7a2dee42c9973646ed70b1b6dd674f41bb433eb4f797d178642
+gotest_hook\tb6b5bb66ff07d63abf0dc99f1edea3f73c8a8c620d4a974b767bdc5bc9b88ef4
+package_verifier\tfef0aaf847dbeb4e581eca569c2492aa293a1ce82965241687e48f646761e6ce
```

The lower seam's library-emission mode remains the product mechanism that
supplies the generated files; this backend consumes it without changing
product source. The backend validates the complete `library <orig> -> <gen>`
transcript before `go test` starts, and fails closed if any selected source is
missing, duplicated, malformed, or mapped to a different contract output.

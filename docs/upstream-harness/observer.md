# S157.3: minimal independent observer

Story `04e86c3f7fc0` adds one Go record reader to the existing backend gate. It
does not inspect test source, parse directives, discover files, choose actions,
or decide applicability. Those decisions remain entirely inside the
authenticated Go 1.27 `cmd/internal/testdir` runner.

For each Bash++ mode, `observer.go` reads only the event streams already
produced for `fixedbugs/issue21808.go` and `cmplxdivide.go`. It records:

- the pinned Go release, upstream runner, integration patches, backend hook,
  and Bash++ tool identity;
- the exact ordered `A\n\nB\n` comparison selected by the upstream harness;
- the observed phase exit and timeout bit; and
- the observed terminal state.

The output is one compact JSON receipt per mode in the gate's temporary
evidence directory. The interpreted receipt requires issue21808 to pass and
cmplxdivide to retain its current exit-2 failure. The compiled receipt requires
both anchors to pass with phase exit 0. No digest chain, packet format, broad
negative suite, or process-management subsystem is added.

The integrated local command passed through `bashy gate` in 47.665 seconds on
2026-09-11. The observer source is authenticated by `backend-pin.tsv`; the
backend gate refuses to run if it changes without an explicit pin update.

The same integrated gate passed on the authorized Linux host through one
coordinator in 3m19.871s at 2026-09-11T07:16Z. The post-run process table was
clean. It reused the S157.2 authenticated identities; no source, tool, corpus,
or runtime pin changed.

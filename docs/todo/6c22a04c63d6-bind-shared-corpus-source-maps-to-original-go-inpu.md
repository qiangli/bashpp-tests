---
id: 6c22a04c63d6
kind: task
title: Bind shared corpus source maps to original Go inputs
seq: 15
status: done
priority: p0
created: 2026-09-09T04:04:30.40658Z
weave: 13
assignee: qiangli
sprint: 118
closed: 2026-09-09T04:48:14.294401Z
---

Sprint118 shared executor source-map provenance hardening. Own only tools/corpus/executor.rb, validate.rb, README.md and tests/corpus/executor_test.rb. No subagents, pushes, story closure, source rewrites. Manager will seed integration corpus commits before launch. Current valid_source_map? checks schema/digest and generic numeric fields only; validator does not bind map sources to exact original source set/hash and per-file mapping bounds. Implement independent validation binding source_kind=go,front_end=gosource-v1,sources exact original filenames/SHAs/Base/Size, mappings source_file/source_file_offset (current CLI) or mapped Source metadata actual serialized schema; verify ranges against original bytes and generated line/col. Avoid allowing empty/fake source maps to certify nonempty mapped program, but do not invent requirement invalid for legitimate empty package. Read Bashy current worktree /Users/qiangli/.bashy/weave/bashy-6497d06f/workspaces/issue-3 internal/agentos/transpile.go map schema; sh new8b6a9c35 Sources/Mapping Source contract in issue28. Coordinate by manager weave comments if schema ambiguous, no product file edits. Real candidate available /tmp/s118-integration/bashy/bin/bashy (tag-enabled diagnostic source-go build, not final default candidate); exact clean source tree at /tmp/s118-integration/* but don't mutate/build it. Native SDK /Users/qiangli/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.27.0.darwin-arm64. Tests meaningful source/map tamper negatives, no fake success as product proof. Preserve capture API Corpus.capture(argv,cwd:,log_prefix:,env:,timeout:), shared executor exact default comparisons. Notify manager of blockers; commit proper Sprint:#118 Story+ID trailers.

Review and acceptance,2026-09-08:
Reviewed and integrated in79c685e. Portable original-source/generated-map fixtures and fail-closed actual byte/name/base/position/marker validation pass19 tests/98 assertions with zero skips. Eight diagnostic real PASS maps independently validated.

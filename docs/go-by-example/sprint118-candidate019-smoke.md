# Sprint 118 candidate019 custom-errors smoke

Candidate019 was authenticated against its reviewed candidate row and then ran
the unchanged `examples/custom-errors/custom-errors.go` source in interpreted
and compiled modes. Both modes exited 0 and printed exactly:

```text
42
can't work with it
```

The compiled artifact was rerun from a separate runtime directory with an empty
`PATH`; it exited 0 with empty stderr. The interpreted and compiled stdout files
have the same SHA-256,
`c851ea148123b33b6a505d75027a1c02ae797aa71b47dfe9878d5f2dc44d25c0`.

The smoke binds manifest
`063669d6155996cdb6fb54e5ad268229003054d6ac5fdca985b7663730414e0a`,
launcher `454c25a8cfb70a45e2bcb4fe57f64e7726164ed1ec8b7e46f3c243f4b87930a4`,
payload `5595bfe9f7993cee114263e4ef9d62c7baf1f17564b10b6fa6087569ea991c2c`,
sh `cb89ee8ffef28b099d6f63b7661692421ee43a20`, and Bashy
`118bb3f6841a57a7010b7858bf02564c445416f7`. Detailed local evidence is retained
at `runtime-integration-019/custom-errors-smoke.json` under the Sprint 118
evidence root. This focused smoke confirms the `errors.AsType` repair; it does
not claim full Go by Example acceptance.

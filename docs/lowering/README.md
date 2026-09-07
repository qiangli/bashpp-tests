# Sprint 117 lowering boundary

`identities.tsv` is an independently checked, exact ordered identity manifest.
It inventories the 62 public AST nodes (all 60 structs in
`syntax/bashpp_nodes.go`, `BashPPAgenticBlock`, and agentic `FuncDecl`), 41
significant expression/type/start-site/class variants, three significant field
edges, the runtime obligation
inventory, approved corpus/profile identities, five Bash# families, and the
33 lowering cases. Start-site ownership is deliberately separate: its 205
rows are not an AST-node inventory.

The AST snapshot includes the public parser change
`25276aa1495735628d9ee0d16e4856b37ee6b237`: `BashPPFuncType` represents a
concrete callable signature, `BashPPCall` also implements `BashPPExpr`, and
`BashPPReturn.Call` retains the positioned returned call. Return `Results` words
remain available for compatibility; the field edge requires consumers to account
for the call, rather than assuming every returned value is only a word.
The typed-operand repair `589d12e2` adds `BashPPReturn.Expr`, a positioned
scalar operator tree with the complete legacy `Results` word retained. This is
another field edge, with no additional node or expression variant.
The scalar-call repair `97353a91` adds `BashPPCall.ArgExprs`. These positioned
arguments own scalar-call evaluation, traversal, and printing. Legacy `Args`
words remain available, but consumers must use the typed edge when present;
Walk visits it instead of visiting the same logical arguments twice. Typed JSON
retains both fields. Parser bytewise/print/mutation tests and typed JSON round
trips verify this ownership; the new edge adds no node or expression variant.

Measured totals are 62 nodes, 15 expression variants, 9 type variants, 15
start-site variants, 2 site-class variants, and 3 field edges: **106 AST
identities**. The field-edge inventory is an explicit significant-edge contract,
not an exhaustive list of every field in every node. These are structural
obligations; neither parser availability nor this inventory proves lowering,
null-checker coverage, interpreted behavior, or compiled parity.

The 33 lowering cases are exactly **18 runtime** cases and **15 deterministic
rejections**. A `run` case may correctly exit non-zero when the specified
runtime behavior is a diagnostic; `reject` means the transpiler must issue the
specified diagnostic and emit no Go.

Run either configured structural contract command (they are intentionally the
same P0 gate):

```sh
ruby tools/lowering/validate.rb --self-test
ruby tools/lowering/validate.rb
```

Make a compiled BASHSHARP33 parity attempt explicitly:

```sh
ruby tools/lowering/validate.rb --parity
# or: ruby tools/lowering/differential.rb
```

It is expected to fail today, honestly: `GOTOOLCHAIN=go1.27.0` resolves the
pinned, checksummed Go binary, but the product has no usable `bashy transpile
--bashpp` compiler yet. A structural pass is not compiler parity.

`tools/lowering/differential.rb` retains every copied input, generated source,
binary, isolated execution state, and JSONL evidence under a printed artifact
directory (or `--artifacts DIR`). Each runtime mode gets a fresh equivalent
cwd/environment/filesystem template. The evidence records status, the raw
stream schema, typed-output schema and proof state, filesystem/environment
effects, stdout/stderr errors, and explicit cancellation/concurrency
observations. Typed output is `unproved-by-this-fixture` unless a fixture
declares and captures that channel; raw stdout is never copied in as typed-value
proof. The latter two report `not-requested` unless a fixture requests them;
their required ownership is still recorded in `runtime_obligations.tsv` and
cannot be claimed as complete merely by P0.

Phase ownership is deliberate: the interpreter owns interpreted semantics;
the generated executable owns lowered semantics; the harness owns identical
state creation, execution controls, structured observation, and comparison.
Source/transpilation artifacts are never discarded. The typed-only
authenticity fixture additionally runs the binary with its original source
absent and with a shell-free `PATH`; it demands direct Go arithmetic, callable,
and control flow and rejects interpreter, shell, and generated-runtime-helper
wrappers. Dynamic shell fallback remains legal for ordinary (non-typed-only)
fixtures.

`--case FAMILY/CASE` is useful for diagnosis, but a subset pass prints
`BASHSHARP33 PARITY SUBSET PASS` and explicitly leaves BASHSHARP33 completion
and compiled compiler/corpus parity unestablished. Even all 33 rows establish
only BASHSHARP33 parity, not compiler/corpus parity.

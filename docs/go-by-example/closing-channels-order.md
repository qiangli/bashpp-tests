# Closing-channels output-order contract

The unchanged upstream `examples/closing-channels/closing-channels.go` is 1,698
bytes with SHA256
`b2ddb4aa5bce6a532fc9bc29e67800e1a31f8da7fb7131f4ee8bde7eecfbe15c`.
Its previous `none` comparator required identical scheduler choices across
separate invocations. The existing concurrency schema explicitly licenses
scheduler interleaving. Normalizer version 6 declares `closing_channel_order`
only for this exact row and digest; no other row or comparator changes.

Let P1, P2 and P3 denote `sent job 1`, `sent job 2` and `sent job 3`; PC is
`sent all jobs`. C1, C2 and C3 denote the matching `received job` lines; CC is
`received all jobs`. F is `received more jobs: false`. Each line includes its
original terminating newline and must occur exactly once.

The source implies these constraints:

- Producer program order: P1 < P2 < P3 < PC.
- Consumer program order and channel FIFO: C1 < C2 < C3 < CC.
- The next send follows the previous producer print: P1 < C2 and P2 < C3.
- Closing the channel follows P3; observing the closed, empty channel follows
  closing it: P3 < CC.
- PC precedes the main goroutine's done receive. CC precedes the consumer's
  done send. The unbuffered handshake precedes the last closed-channel receive
  and final print: PC < F and CC < F.

There is no Pj < Cj constraint: each producer log happens **after** its send,
and the receiver can run between those operations. PC and CC can appear in
either order. The buffer holds five values but the source sends only three,
so no buffer-full synchronization adds further edges. A FIFO queue model with
explicit send, receive, close and unbuffered done-handshake transitions projects
exactly 42 possible nine-line traces. The tests enumerate all 362,880 event
permutations and prove that the comparator accepts exactly that model's set.
They also reject missing, duplicate, extra, misvalued and malformed lines.
Stderr, process exit, deadlines and effects retain their existing comparisons.

A real Go 1.27 native build of the unchanged source was run 192 times, with
explicit GOMAXPROCS values 1, 2 and 4 (64 each), five-second run deadlines and
no inherited environment. All runs exited zero with empty stderr; they produced
six distinct stdout orders, all accepted. SDK binary SHA256 is
`a19a71df81715c12d9a7e81bab036c12696fec1ddbd4258b48a2131a9080b267`;
the built native program SHA256 is
`a5f58d87f538984c04410936c66e0dba526f9ee8e6a8c111458de084ebfd8538`.
Every argv, environment, cwd, deadline, source/binary digest and raw stream is
retained under
`/Users/qiangli/.local/state/bashy/sprint118-evidence/closing-channels-order-review/`.
The six distinct real outputs and their capture provenance are retained in
`tests/go-by-example/fixtures/closing-channels/` for offline regression coverage.
These observations support the source argument; they do not claim that all
42 schedules were observed natively or certify any product mode.

Candidate005's interpreted order P1,C1,C2,P2,P3,C3,CC,PC,F is legal under this
source model. Its historical mismatch verdict, raw evidence and evidence root
remain unchanged. The revised contract must be bound into a new complete
candidate replay before any updated corpus verdict is reported.

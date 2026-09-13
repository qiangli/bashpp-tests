# Sprint 162 backend seam 2 findings

| root | first cause | mechanism | status |
| --- | --- | --- | --- |
| fixture:rundir-link | an absolute generated source with no `-o` makes `cmd/compile` write `main.o` in the phase working directory, while the old artifact computation named the temporary-module path | derive implicit compiler output from the generated basename in the upstream phase working directory | fixed in 7f2470a |
| testdir:fixedbugs/bug414.go | compiled link phase looked for the default generated `main.o` in the upstream phase directory while the backend recorded it beside the generated source | directory/link implicit compiler output | fixed in 7f2470a |
| testdir:fixedbugs/bug437.go | same directory/link implicit compiler output | directory/link implicit compiler output | fixed in 7f2470a |
| testdir:fixedbugs/issue22941.go | same directory/link implicit compiler output | directory/link implicit compiler output | fixed in 7f2470a |
| testdir:fixedbugs/issue6789.go | same directory/link implicit compiler output | directory/link implicit compiler output | fixed in 7f2470a |
| testdir:typeparam/issue47514c.go | same directory/link implicit compiler output | directory/link implicit compiler output | fixed in 7f2470a |
| testdir:typeparam/issue47775.go | same directory/link implicit compiler output | directory/link implicit compiler output | fixed in 7f2470a |
| testdir:typeparam/issue48185a.go | same directory/link implicit compiler output | directory/link implicit compiler output | fixed in 7f2470a |
| testdir:typeparam/issue48185b.go | same directory/link implicit compiler output | directory/link implicit compiler output | fixed in 7f2470a |
| testdir:typeparam/issue50121b.go | same directory/link implicit compiler output | directory/link implicit compiler output | fixed in 7f2470a |
| testdir:typeparam/issue51250a.go | same directory/link implicit compiler output | directory/link implicit compiler output | fixed in 7f2470a |
| testdir:typeparam/issue51367.go | same directory/link implicit compiler output | directory/link implicit compiler output | fixed in 7f2470a |
| testdir:typeparam/mdempsky/10.go | same directory/link implicit compiler output | directory/link implicit compiler output | fixed in 7f2470a |

## Negative control

The existing body-less run fixture remains negative: it compiles directly but
fails to link an unresolved external declaration. This change only corrects
the location of a compiler-produced object; it does not turn a link failure
into a pass.

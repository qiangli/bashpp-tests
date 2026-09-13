// A run recipe may compile this declaration, but its linker must reject the
// unresolved external symbol; direct compilation is not a run-path bypass.
package main

func external()

func main() { external() }

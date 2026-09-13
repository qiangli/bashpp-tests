// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
//
// Bind a staged source/driver/asset tree before the phase receives it. Build
// tools may add go.sum, but may never alter an already-bound input. Ported
// from tools/go-by-example/inputs.rb.
//
// A binding also declares WHOSE input it is. The pinned corpus directory and the
// shared binary directory are "shared" -- every mode reads them, so a change
// there invalidates every mode. A staging tree that only one mode is ever given
// (src/oracle, src/interpreted, src/compiled, compiled/transpile,
// compiled/build) belongs to that mode alone. Scope changes nothing about how
// strictly a tree is compared; it only decides which phases that tree is an
// input to, so that a mutation is charged to the mode that caused it instead of
// silently suppressing an unrelated mode that was never handed the tree.
package main

import (
	"sort"
	"strings"
)

var inputScopes = []string{"shared", "oracle", "interpreted", "compiled"}

type InputBinding struct {
	Root           string
	Scope          string
	allowAdditions bool
	before         map[string]*Object
}

func newInputBinding(root string, allowAdditions bool, scope string) *InputBinding {
	if !contains(inputScopes, scope) {
		panic("unknown binding scope: " + scope)
	}
	before, err := snapshot(root)
	if err != nil {
		panic(err)
	}
	return &InputBinding{Root: root, Scope: scope, allowAdditions: allowAdditions, before: before}
}

// Changes: every entry bound before the phase must still be byte-identical
// afterwards, and unless additions were declared the entry set may not grow
// either. A removed or replaced entry is caught by the first test (its `after`
// value is nil or different), so declaring additions never permits a bound
// byte to move.
func (b *InputBinding) Changes() []string {
	after, err := snapshot(b.Root)
	if err != nil {
		return []string{"!" + errorClass(err)}
	}
	var altered, added []string
	for name, entry := range b.before {
		if other, ok := after[name]; !ok || !snapshotEqual(other, entry) {
			altered = append(altered, "!"+name)
		}
	}
	sort.Strings(altered)
	if !b.allowAdditions {
		for name := range after {
			if _, ok := b.before[name]; !ok {
				added = append(added, "+"+name)
			}
		}
		sort.Strings(added)
	}
	return append(altered, added...)
}

func (b *InputBinding) Unchanged() bool { return len(b.Changes()) == 0 }

func errorClass(err error) string {
	switch err.(type) {
	case *ContractError:
		return "Corpus::ContractError"
	default:
		return "StandardError"
	}
}

// bindingsFor: bindings the given phase actually consumes: the shared ones
// plus, when the phase belongs to a mode, that mode's own staging trees.
func bindingsFor(bindings []*InputBinding, scopes []string) []*InputBinding {
	var out []*InputBinding
	for _, b := range bindings {
		if contains(scopes, b.Scope) {
			out = append(out, b)
		}
	}
	return out
}

func bindingsIntact(bindings []*InputBinding, scopes []string) bool {
	for _, b := range bindingsFor(bindings, scopes) {
		if !b.Unchanged() {
			return false
		}
	}
	return true
}

// enforceBindings marks the result as an input mutation when any consumed
// binding changed during the phase.
func enforceBindings(result *Object, bindings []*InputBinding, scopes []string) *Object {
	var details []string
	for _, b := range bindingsFor(bindings, scopes) {
		changes := b.Changes()
		if len(changes) == 0 {
			continue
		}
		details = append(details, b.Root+" ("+strings.Join(changes, ",")+")")
	}
	if len(details) == 0 {
		return result
	}
	result.Set("state", "input_mutation")
	result.Set("detail", "staged original source, generated driver, or declared asset changed during phase: "+strings.Join(details, "; "))
	return result
}

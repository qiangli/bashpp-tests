# S162.6 reproducer A (the corpus mechanism): the shell itself opens a
# process-substitution FIFO through a redirection. Classic prints three lines
# and exits 0; under Bash++ activation the redirection open never returns.
read -r x < <(echo hello)
echo "redir: $x"
while read -r y; do echo "loop: $y"; done < <(printf 'a\nb\n')
echo done

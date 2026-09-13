# S162.6 reproducer B (the isolation gap behind A): a Classic named FIFO whose
# peer is an external process. Classic prints two lines; under Bash++
# activation the shell's own open of "$d/p" waits for a peer registered in the
# Bash++ task group, which an external process can never be.
d=$(mktemp -d); mkfifo "$d/p"
cat "$d/p" &
echo classic-fifo > "$d/p"
wait
echo "wrote via external reader"
rm -rf "$d"

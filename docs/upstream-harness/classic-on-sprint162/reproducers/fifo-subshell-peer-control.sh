# S162.6 negative-set control: the same named FIFO with a shell subshell as
# the peer works in both modes (both ends open through the shell's own path).
d=$(mktemp -d); mkfifo "$d/p"
( echo bg-writer > "$d/p" ) &
read -r v < "$d/p"; wait
echo "read: $v"
rm -rf "$d"

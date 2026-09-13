# S162.6 reproducer A' (output side): the shell opens a >(...) FIFO for
# writing. Classic prints "out" and exits 0; Bash++ activation never returns.
echo out > >(cat)
wait

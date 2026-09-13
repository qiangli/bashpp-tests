# S162.6 positive control: the same FIFO handed to an external command is
# opened natively by that command, not by the shell, and works in both modes.
cat <(echo viacat)

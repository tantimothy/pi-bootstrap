if [ -z "$TMUX" ]; then
    # Try creating an independent clone of session 0 with a unique process ID name
    tmux new-session -t 0 -s "client_$$" \; set-option destroy-unattached on 2>/dev/null \
    || tmux new-session -s 0
fi

#!/bin/bash

BOLD=$'\033[1m'
CYAN=$'\033[36m'
DIM=$'\033[2m'
RESET=$'\033[0m'

# The outer deploy.sh INFO policy (info.yaml + lib/run-info.sh) runs on the
# HOST and is unreachable once you're attached in here — this is the
# in-container equivalent, built from values already available inside the
# container rather than trying to read info.yaml, which isn't copied into
# the image. Piped through `less -r` (not a plain cat+read) so long output
# can be paged, with -r passing color escape codes through instead of
# showing them as literal garbage.
show_info() {
    cat <<EOF | less -r
${BOLD}🔎 Kali Legion — Environment Info${RESET}

Legion is a graphical, automated recon tool — it has no useful CLI/TUI
mode of its own, so this container has no in-menu "launch" option. Use
the ${CYAN}Legion${RESET} desktop entry (or ${DIM}scripts/launch-legion.sh${RESET} directly) to
open its GUI on the host's X11/XWayland display instead.

${BOLD}Useful commands${RESET} (run these on the HOST, not in this container):
  ${DIM}docker exec -it \${CONTAINER_NAME:-running-legion-rig} bash${RESET}
  ${DIM}docker exec -it \${CONTAINER_NAME:-running-legion-rig} /usr/local/bin/entrypoint.sh${RESET}
  ${DIM}docker logs \${CONTAINER_NAME:-running-legion-rig}${RESET}

Full tool reference and deployment policies (FAST/CLEAN/REBUILD/etc.):
  environments/kali-legion/README.md in the pi-bootstrap repo.
EOF
}

show_menu() {
    dialog --clear --backtitle "Headless Kali Legion Service Router" \
    --title " Tool Attachment Submenu " \
    --menu "Container is active. Select an interface context to launch:" 12 66 3 \
    1 "Environment Info" \
    2 "Drop to Container Bash Shell" \
    3 "Detach and Return to Host OS" 2> /tmp/menu_choice

    return $?
}

while true; do
    show_menu
    menu_status=$?
    choice=$(cat /tmp/menu_choice)

    # dialog writes nothing to /tmp/menu_choice on Cancel/ESC, so $choice
    # comes back empty — without this check that empty value falls through
    # to the catch-all "*)" arm below, which is Detach, silently exiting
    # the whole container session back to the host on a stray ESC/cancel.
    # Redraw instead; only an explicit "3" selection should ever detach.
    if [ "$menu_status" -ne 0 ] || [ -z "$choice" ]; then
        continue
    fi

    case $choice in
        1)
            show_info ;;
        2)
            clear
            echo "Dropping to container Bash. Type 'exit' to return to menu."
            /bin/bash ;;
        3)
            clear
            echo "🚪 Detached. Container remains running headlessly in the background."
            exit 0 ;;
        *)
            # Unrecognized/empty tag — the menu_status check above already
            # catches a genuine Cancel/ESC, but treat anything else the same
            # way defensively: redraw rather than falling through to Detach.
            continue ;;
    esac
done

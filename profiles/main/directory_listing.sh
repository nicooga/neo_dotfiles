# Objective: provide a nice looking directory listing command that:
# - Lists all files, including folders and hidden files
# - Displays file sizes in human readable format (2B, 3KB, 3MB, 4GB, etc.)
# - Supports nesting to L levels (L=1 by default) and provides visual feedback on what files belong to what folder
main() {
    install_eza
    define_alias
}

install_eza() {
    if !type eza >/dev/null 2>&1; then
        brew install eza
    fi
}

define_alias() {
    alias ll='eza -albgh --level=1 --icons'
}

main

main() {
    install
    activate
}

install() {
    if ! command -v direnv >/dev/null 2>&1; then
        do_install
    fi
}

do_install() {
    brew install direnv
}

activate() {
    eval "$(direnv hook zsh)"
}

main

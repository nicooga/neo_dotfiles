installation_dir=~/.zsh-git-prompt

main() {
  install
  activate
}

install() {
  if [ ! -d "$installation_dir" ]; then
    do_install
  fi
}

do_install() {
  git clone https://github.com/olivierverdier/zsh-git-prompt $installation_dir --depth=1
}

activate() {
  PROMPT='%B%m%~%b$(git_super_status) %# '
}

main
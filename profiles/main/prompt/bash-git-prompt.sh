installation_dir=~/.bash-git-prompt

main() {
  install
  GIT_PROMPT_ONLY_IN_REPO=1
  source $installation_dir/gitprompt.sh
}

install() {
  if [ ! -d "$installation_dir" ]; then
    do_install
  fi
}

do_install() {
  git clone https://github.com/magicmonty/bash-git-prompt.git  $installation_dir --depth=1
}

main
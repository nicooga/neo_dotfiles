repo='https://github.com/spaceship-prompt/spaceship-prompt'
installation_dir=~/.spaceship-prompt
zshlib_dir=~/.zsh-functions
spaceship_script_name=spaceship.zsh

main() {
  add_folder_to_zsh_path
  install
  activate_spaceship_prompt
}

add_folder_to_zsh_path() {
  mkdir -p $zshlib_dir
  fpath=($zshlib_dir $fpath)
}

install() {
  if !type spaceship >/dev/null 2>&1; then
    do_install
  fi
}

do_install() {
  brew install spaceship
}

activate_spaceship_prompt() {
  source "/opt/homebrew/opt/spaceship/spaceship.zsh"
}

main

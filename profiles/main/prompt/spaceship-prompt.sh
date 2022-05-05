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
  fpath=($zshlib_dir, $fpath)
}

install() {
  if [ ! -e "$zshlib_dir/$spaceship_script_name" ]; then
    do_install
  fi
}

do_install() {
  clone_repo
  link_spaceship_script
}

clone_repo() {
  if [ ! -d "$installation_dir" ]; then
    do_install
  fi
}

do_clone_repo() {
  git clone $repo $installation_dir --depth=1
}

link_spaceship_script() {
  ln -sf "$installation_dir/$spaceship_script_name" "$zshlib_dir/"
}

activate_spaceship_prompt() {
  autoload -U promptinit; promptinit
  prompt spaceship
}

main

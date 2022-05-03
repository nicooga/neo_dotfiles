### How to use

This is for the me of the future.
You are welcome handsome.

1. Clone repo:
  ~~~sh
  git clone git@github.com:nicooga/neo_dotfiles.git ~/dotfiles
  ~~~

2. Set an appropriate config file:
  ~~~
    config_file=~/.bashrc
    # ... or
    config_file=~/.zshrc
  ~~~

3. Set `$DOTFILES`:
  ~~~
  echo 'export DOTFILES=~/dotfiles' >> $config_file
  ~~~

4. Choose an appropiate profile here:
  ~~~
    echo 'export DOTFILES_PROFILE=bash' >> $config_file
    # ... or
    echo 'export DOTFILES_PROFILE=zsh' >> $config_file
  ~~~

5. Source dotfiles main config file:
  ~~~
    echo 'source $DOTFILES/main.sh' >> $config_file
  ~~~

6. Restart, then run "installation" to perform some one-time settings
  ~~~
    install_dotfiles
  ~~~

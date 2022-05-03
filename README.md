### How to use

This is for the me of the future.
You are welcome handsome.

~~~sh
git clone git@github.com:nicooga/neo_dotfiles.git ~/dotfiles

echo 'export DOTFILES=~/dotfiles' >> ~/.bashrc

# Choose an appropiate profile here
echo 'source $DOTFILES/profiles/bash.sh' >> ~/.bashrc
# ... or
echo 'source $DOTFILES/profiles/zsh.sh' >> ~/.bashrc

# Restart, then run "installation" to perform some one-time settings
install_dotfiles
~~~

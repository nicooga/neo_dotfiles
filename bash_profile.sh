source $DOTFILES/configs/aliases.sh
source $DOTFILES/configs/asdf.sh
source $DOTFILES/configs/direnv.sh
source $DOTFILES/configs/homebrew.sh
source $DOTFILES/configs/editor.sh
source $DOTFILES/configs/dotfiles_bin.sh
source $DOTFILES/configs/prompt.sh

# Some software like elasticsearch adds binaries here
export PATH=~/.local/bin:$PATH

source $DOTFILES/configs/aliases.sh
source $DOTFILES/configs/asdf.sh
source $DOTFILES/configs/direnv.sh
source $DOTFILES/configs/homebrew.sh
source $DOTFILES/configs/editor.sh

# Choose One
# source $DOTFILES/configs/prompt/powerline.sh
source $DOTFILES/configs/prompt/oh_my_posh.sh

# Some software like elasticsearch adds binaries here
export PATH=~/.local/bin:$PATH

git config --global core.excludesfile $DOTFILES/.gitignore_global
git config --global user.name 'Nicolas Oga'
git config --global user.email '2112.oga@gmail.com'

# Global Claude Code instructions (e.g. never GPG-sign commits, see claude-config/CLAUDE.md)
mkdir -p ~/.claude
ln -sf $DOTFILES/claude-config/CLAUDE.md ~/.claude/CLAUDE.md

# Git aliases
git config --global alias.st 'status'
git config --global alias.co 'checkout'
git config --global alias.ci 'commit'
git config --global alias.amend 'commit --amend --no-edit'

alias ebashprofile='gvim $DOTFILES'
alias bx='bundle exec'
alias mailhog="docker run -p 1025:1025 -p 8025:8025 mailhog/mailhog"
alias reload='source $DOTFILES/bash_profile.sh'

alias git_init_personal='\
  git config user.email "2112.oga@gmail.com" && \
  git config user.name "Nicolas Oga" \
'

alias git_init_toptal='\
  git config user.email "nicolas.oga@toptal.com" && \
  git config user.name "Nicolas Oga" \
'

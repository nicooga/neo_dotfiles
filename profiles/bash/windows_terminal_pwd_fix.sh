# Tell Windows what is the current directory
# This workaround allows windows terminal to open split panels in the same directory.
export PROMPT_COMMAND=${PROMPT_COMMAND:+"$PROMPT_COMMAND; "}'printf "\e]9;9;%s\e\\" "$(wslpath -w "$PWD")"'
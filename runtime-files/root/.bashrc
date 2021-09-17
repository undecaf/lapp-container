export PS1='\[\033[1;35m\]\[\033[4;35m\]\u\[\033[0m\]\[\033[1;35m\]@\H\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]# '
export HISTCONTROL=erasedups:ignoreboth

alias ll='ls -lA'

# Load the current runtime environment
. /usr/local/lib/env.inc
load_env

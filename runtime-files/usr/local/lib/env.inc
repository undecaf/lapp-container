#!/bin/bash

#
# Runtime environment utils
# =========================
#
# Usage: source THIS_FILE
#

# Runtime environment saved here
ENV_DIR=/var/run/s6/container_environment

# Container environment variables that can be changed by 'lapp env'
RE_CONT_ENV_VARS='MODE|PHP_[^=]+'


# --------------------------------------------------------------------------

# Sets a variable of the runtime environment.
#
# Arguments:
#   $1  variable name
#   $2  variable value
#
set_var() {
    /bin/mkdir -p ${ENV_DIR}
    echo "$2" >${ENV_DIR}/$1
}


# --------------------------------------------------------------------------

# Replaces the runtime environment with the current environment plus
# the specified NAME=VALUE pairs. COntainer environment variables are
# included only if $1 is non-empty; the leading 'LAPP_' is removed from 
# container environment variable names.
#
# Arguments:
#   $1           if non-empty then container environment variables
#                (whose names start with 'LAPP_') are included, else
#                they are ignored
#   $2, $3, ...  (optional) NAME=VALUE pairs
#
save_env() {
    local RE_CONT_ENV='^(LAPP_('${RE_CONT_ENV_VARS}'))=(.*)$'
    local RE_OTHER_ENV='^([^=]+)=(.*)$'
    local PAIRS
    local PAIR
    local INCLUDE_CONT_ENV_VARS="$1"
    shift

    # Get the current environment and preserve embedded spaces
    IFS=$'\n'
    PAIRS=($(env))

    # Add specified name/value pairs
    IFS=' '
    PAIRS+=("$@")

    /bin/mkdir -p ${ENV_DIR}
    /bin/rm -f ${ENV_DIR}/*

    for PAIR in "${PAIRS[@]}"; do
        if [[ $PAIR =~ ${RE_CONT_ENV} ]]; then
            # Set a container environment variable if requested
            test -n "$INCLUDE_CONT_ENV_VARS" && echo "${BASH_REMATCH[3]}" >${ENV_DIR}/${BASH_REMATCH[2]} || true
        elif [[ $PAIR =~ ${RE_OTHER_ENV} ]]; then
            # Set a plain environment variable
            echo "${BASH_REMATCH[2]}" >${ENV_DIR}/${BASH_REMATCH[1]}
        else
            # Unset a plain environment variable
            rm -f "${ENV_DIR}/${PAIR}"
        fi
    done
}


# --------------------------------------------------------------------------

# Exports the saved runtime environment variables into the current script.
#
load_env() {
    . <(/bin/s6-envdir ${ENV_DIR} /bin/sh -c 'export')
}

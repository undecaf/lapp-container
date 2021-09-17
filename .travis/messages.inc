# Returns success if a certain message ($1) is generated at stdout
# by a command ($2, ...).
verify_msg() {
    echo "verify_msg: '$1'" >&2

    local MSG
    local CMD
    MSG=$1
    CMD=$2
    shift 2

    $CMD "$@" 2>/dev/null | grep -q -F "$MSG" \
        || { echo "verify_msg failed: '$1'" >&2; return 1; }
}

# Returns success if a certain message ($1) is generated at stderr
# by a command ($2, ...).
verify_error() {
    echo "verify_error: '$1'" >&2

    local MSG
    local CMD
    MSG=$1
    CMD=$2
    shift 2

    $CMD "$@" 2>&1 >/dev/null | grep -q -F "$MSG" \
        || { echo "verify_error failed: '$1'" >&2; return 1; }
}


echo $'\n*************** Command abbreviation and help messages\n'
verify_msg 'Available commands' ./lapp -h
verify_msg 'Available commands' ./lapp --help
verify_msg 'Runs LAPP' ./lapp run -h
verify_msg 'Runs LAPP' ./lapp r -h
verify_msg 'Composer command' ./lapp c -h


echo $'\n*************** Error handling\n'
verify_error 'Missing command' ./lapp
verify_error 'Unknown or ambiguous command' ./lapp nosuchcommand
verify_error 'Unknown or ambiguous command' ./lapp s
verify_error 'No argument was found' ./lapp composer
verify_error 'Container engine' ./lapp run -e nosuchengine
verify_error 'Invalid option' ./lapp run -L a:b
verify_error 'Cannot own volume' ./lapp run -o
verify_error 'Cannot own volume' ./lapp run -O

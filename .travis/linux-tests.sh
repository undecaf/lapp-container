#!/bin/bash

# Runs lapp with the specified arguments and echoes the command line
# and the environment to stdout.
lapp_() {
    local CMD
    CMD=$1
    shift

    local TAG
    test "$CMD" = 'run' && TAG="-T $PRIMARY_TAG" || true

    echo '--- '$(env | grep 'LAPP_')" ./lapp $CMD $TAG $@"
    ./lapp $CMD $TAG "$@" \
        || { echo "--- $CMD command failed" >&2; return 1; }
}

# Returns success if all specified containers exist.
verify_containers_exist() {
    echo "verify_containers_exist: $@" >&2
    docker container inspect "$@" &>/dev/null \
        || { echo "verify_containers_exist failed: $@" >&2; return 1; }
}

# Returns success if all specified containers are running.
verify_containers_running() {
    echo "verify_containers_running: $@" >&2
    ! docker container inspect --format='{{.State.Status}}' "$@" | grep -v -q 'running' \
        || { echo "verify_containers_running failed: $@" >&2; return 1; }
}

# Returns success if all specified volumes exist.
verify_volumes_exist() {
    echo "verify_volumes_exist: $@" >&2
    docker volume inspect "$@" &>/dev/null \
        || { echo "verify_volumes_exist failed: $@" >&2; return 1; }
}

# Returns success if the specified command ($2, $3, ...) succeeds 
# within some period of time ($1 in s).
verify_cmd_success() {
    local TIMEOUT=$1
    local STEP=2
    local T=0
    shift

    echo "verify_cmd_success: $@" >&2

    while ! "$@"; do
        sleep $STEP
        T=$((T+STEP))
        test $T -lt $TIMEOUT \
            || { echo "verify_cmd_success failed: $@" >&2; docker logs lapp >&2; return 1; }
    done

    return 0
}

# Returns success if the specified command ($2, $3, ...) _fails_ 
# after some period of time ($1 in s).
verify_cmd_failed() {
    local TIMEOUT=$1
    shift

    echo "verify_cmd_failed: $@" >&2

    sleep $TIMEOUT

    if ! "$@"; then
        return 0

    else
        echo "verify_cmd_failed failed: $@" >&2
        docker logs lapp >&2
        return 1
    fi
}

# Returns success if a message ($2) is found within some period 
# of time ($1 in s) in the Docker logs for container $3 (defaults
# to 'lapp').
verify_in_logs() {
    echo "verify_in_logs: '$2'" >&2

    local STEP=2
    local T=0

    while ! docker logs "${3:-lapp}" 2>&1 | grep -q -F "$2"; do
        sleep $STEP
        T=$((T+STEP))
        test $T -lt $1 \
            || { echo "verify_in_logs failed: '$2'" >&2; docker logs "${3:-lapp}" >&2; return 1; }
    done

    return 0
}

# Returns success if a message ($2) is _not_ found after some period 
# of time ($1 in s) in the Docker logs for container $3 (defaults
# to 'lapp').
verify_not_in_logs() {
    echo "verify_not_in_logs: '$2'" >&2

    sleep $1

    if docker logs "${3:-lapp}" 2>&1 | grep -q -v -F "$2"; then
        return 0

    else
        echo "verify_not_in_logs failed: '$2'" >&2
        docker logs "${3:-lapp}" >&2
        return 1
    fi
}

# Cleans up container and volumes after a test
cleanup() {
    lapp_ stop --rm "$@" -t 1
    docker volume prune --force >/dev/null
}


# Set environment variables for the current job
source .travis/setenv.inc

# LAPP installation URLs
HOST_IP=127.0.0.1
HTTP_PORT=8080
HTTPS_PORT=8443
DB_PORT=3000
README_URL=http://$HOST_IP:$HTTP_PORT/readme.html
README_URL_SECURE=https://$HOST_IP:$HTTPS_PORT/readme.html
SYNTAX_ERR_URL=http://$HOST_IP:$HTTP_PORT/syntax-err.php
RUNTIME_ERR_URL=http://$HOST_IP:$HTTP_PORT/runtime-err.php
MODE_TEST_URL=http://$HOST_IP:$HTTP_PORT/mode-test.php

# Timeouts/delays in s
SUCCESS_TIMEOUT=10
FAILURE_TIMEOUT=5
PIPE_DELAY=2

# Used to capture output
TEMP_FILE=$(mktemp)


echo $'\n*************** Testing '"image $PRIMARY_IMG" >&2

# Clean up Docker on exit
trap 'set +e; cleanup;' EXIT

# Exit with error status if any verification fails
set -e


# Test help and error handling
source .travis/messages.inc


# Test basic container and volume status
echo $'\n*************** Basic container and volume status' >&2

echo $'\nVerifying running container and existing volumes' >&2
lapp_ run
verify_containers_running lapp
verify_volumes_exist lapp-www lapp-pgdata

verify_error 'Cannot run container' ./lapp run

lapp_ stop -t 1
verify_containers_exist lapp
! verify_containers_running lapp
verify_volumes_exist lapp-www lapp-pgdata

cleanup

echo $'\nVerifying removed container and retained volumes' >&2
lapp_ run

lapp_ stop --rm
! verify_containers_exist lapp
verify_volumes_exist lapp-www lapp-pgdata

docker volume prune --force >/dev/null

echo $'\nVerifying argument passthrough' >&2
lapp_ run --label foo=bar
test "$(docker inspect --format '{{.Config.Labels.foo}}' lapp)" = 'bar'

cleanup

lapp_ run -- --label foo=bar
test "$(docker inspect --format '{{.Config.Labels.foo}}' lapp)" = 'bar'

cleanup


# Test logging
echo $'\n*************** Logging' >&2

echo $'\nVerifying PHP version and logging at startup and shutdown' >&2
lapp_ run
verify_in_logs $SUCCESS_TIMEOUT " PHP $PHP_VERSION"
verify_in_logs $SUCCESS_TIMEOUT 'ready to accept connections'

verify_cmd_success $SUCCESS_TIMEOUT lapp_ stop -R -l >$TEMP_FILE
grep -q 'Stopping the container' $TEMP_FILE

docker volume prune --force >/dev/null


# Test HTTP and HTTPS connectivity
echo $'\n*************** HTTP and HTTPS connectivity' >&2

echo $'\n'"Getting $README_URL and $README_URL_SECURE" >&2
lapp_ run
verify_cmd_success $SUCCESS_TIMEOUT curl -Is $README_URL | grep -q '200 OK'
verify_cmd_success $SUCCESS_TIMEOUT curl -Isk $README_URL_SECURE | grep -q '200 OK'

cleanup

TEST_PORT=4711
TEST_URL=${README_URL/$HTTP_PORT/$TEST_PORT}

lapp_ run -p $TEST_PORT,

echo $'\n'"Getting $TEST_URL, $README_URL_SECURE not listening" >&2
verify_cmd_success $SUCCESS_TIMEOUT curl -Is $TEST_URL | grep -q '200 OK'
verify_cmd_failed $FAILURE_TIMEOUT curl -Isk $README_URL_SECURE

cleanup

TEST_URL=${TEST_URL/http:/https:}

lapp_ run -p ,$TEST_PORT

echo $'\n'"Getting $TEST_URL, $README_URL not listening" >&2
verify_cmd_success $SUCCESS_TIMEOUT curl -Isk $TEST_URL | grep -q '200 OK'
verify_cmd_failed $FAILURE_TIMEOUT curl -Is $README_URL

cleanup


# Test PHP error logging
echo $'\n*************** PHP error logging\n' >&2

lapp_ run
verify_in_logs $SUCCESS_TIMEOUT 'AH00094'
docker cp .travis/$(basename $SYNTAX_ERR_URL) lapp:/var/www/localhost/public/
verify_cmd_success $SUCCESS_TIMEOUT curl -Is $SYNTAX_ERR_URL | grep -q '500 Internal Server Error'
verify_in_logs $SUCCESS_TIMEOUT 'syntax error'

docker cp .travis/$(basename $RUNTIME_ERR_URL) lapp:/var/www/localhost/public/
verify_cmd_success $SUCCESS_TIMEOUT curl -Is $RUNTIME_ERR_URL | grep -q '200 OK'
verify_in_logs $SUCCESS_TIMEOUT 'Undefined variable'

cleanup


# Test database
echo $'\n*************** PostgreSQL connectivity, custom credentials and collation\n' >&2

lapp_ run -P $HOST_IP:$DB_PORT
verify_in_logs $SUCCESS_TIMEOUT 'Random password'
verify_in_logs $SUCCESS_TIMEOUT 'ready to accept connections'
verify_cmd_success $SUCCESS_TIMEOUT pg_isready -h $HOST_IP -p $DB_PORT -d postgres -U postgres -q

cleanup

LAPP_PG_PASSWORD=123456 lapp_ run -P $HOST_IP:$DB_PORT --env LANG=es
verify_not_in_logs $SUCCESS_TIMEOUT 'Random password'
verify_in_logs $SUCCESS_TIMEOUT 'ready to accept connections'
verify_in_logs $SUCCESS_TIMEOUT 'spanish'
verify_cmd_success $SUCCESS_TIMEOUT pg_isready -h $HOST_IP -p $DB_PORT -d postgres -U postgres -q

cleanup


# Test custom container name and hostname
echo $'\n*************** Custom container name and hostname\n' >&2
CONT_NAME=foo
HOST_NAME=dev.under.test

lapp_ run
test "$(docker exec lapp hostname)" = lapp.${HOSTNAME}
cleanup

LAPP_NAME=$CONT_NAME lapp_ run -H $HOST_NAME
test "$(docker exec $CONT_NAME hostname)" = $HOST_NAME
cleanup -n $CONT_NAME


# Test volume names, working directories and ownership
echo $'\n*************** Volume names, bind mounts and ownership, and volume persistence' >&2
WWW_VOL='./www-volume/test-www'
PG_VOL="$(readlink -f .)/postgres volume/test-pg"

echo $'\nTesting volume names and persistence' >&2
LAPP_WWW_VOL=$(basename "$WWW_VOL") lapp_ run -V $(basename "$PG_VOL")
verify_volumes_exist $(basename "$WWW_VOL") $(basename "$PG_VOL")
verify_in_logs $SUCCESS_TIMEOUT 'SSL certificate'
FINGERPRINT="$(docker exec lapp openssl x509 -noout -in /var/www/localhost/.certs/default.pem -fingerprint -sha256)"

lapp_ stop --rm -t 1
LAPP_WWW_VOL=$(basename "$WWW_VOL") lapp_ run -V $(basename "$PG_VOL")
verify_in_logs $SUCCESS_TIMEOUT 'SSL certificate'
test "$FINGERPRINT" = "$(docker exec lapp openssl x509 -noout -in /var/www/localhost/.certs/default.pem -fingerprint -sha256)"

cleanup

echo $'\nTesting bind-mounted volumes and persistence' >&2
LAPP_PG_VOL="$PG_VOL" lapp_ run -v "$WWW_VOL"

verify_cmd_success $SUCCESS_TIMEOUT sudo test -f "$WWW_VOL/public/index.html"
! sudo test -O "$WWW_VOL/public/index.html"
! sudo test -G "$WWW_VOL/public/index.html"

verify_cmd_success $SUCCESS_TIMEOUT sudo test -f "$PG_VOL/PG_VERSION"
! sudo test -O "$PG_VOL/PG_VERSION"
! sudo test -G "$PG_VOL/PG_VERSION"

verify_in_logs $SUCCESS_TIMEOUT 'SSL certificate'
FINGERPRINT="$(sudo openssl x509 -noout -in "$WWW_VOL/.certs/default.pem" -fingerprint -sha256)"

lapp_ stop --rm -t 1
LAPP_PG_VOL="$PG_VOL" lapp_ run -v "$WWW_VOL"
verify_in_logs $SUCCESS_TIMEOUT 'SSL certificate'
test "$FINGERPRINT" = "$(sudo openssl x509 -noout -in "$WWW_VOL/.certs/default.pem" -fingerprint -sha256)"

cleanup
sudo rm -rf "$WWW_VOL" "$PG_VOL"

echo $'\nTesting bind-mounted volume ownership and persistence' >&2
lapp_ run -v "$WWW_VOL" -o -V "$PG_VOL" -O

verify_cmd_success $SUCCESS_TIMEOUT test -f "$WWW_VOL/public/index.html"
test -O "$WWW_VOL/public/index.html"
test -G "$WWW_VOL/public/index.html"

verify_cmd_success $SUCCESS_TIMEOUT test -f "$PG_VOL/PG_VERSION"
test -O "$PG_VOL/PG_VERSION"
test -G "$PG_VOL/PG_VERSION"

verify_in_logs $SUCCESS_TIMEOUT 'SSL certificate'
FINGERPRINT="$(openssl x509 -noout -in "$WWW_VOL/.certs/default.pem" -fingerprint -sha256)"

lapp_ stop --rm -t 1
lapp_ run -v "$WWW_VOL" -o -V "$PG_VOL" -O
verify_in_logs $SUCCESS_TIMEOUT 'SSL certificate'
test "$FINGERPRINT" = "$(openssl x509 -noout -in "$WWW_VOL/.certs/default.pem" -fingerprint -sha256)"

cleanup
rm -rf "$WWW_VOL" "$PG_VOL"


# Test container environment settings
echo $'\n*************** Container environment settings' >&2

echo $'\nVerifying timezone and language' >&2
LOCALE=de_AT.UTF-8
TZ=Australia/North  # UTC +09:30, does not have DST
TEMP_FILE=$(mktemp)

LAPP_LANG=$LOCALE lapp_ run --env TIMEZONE=$TZ 
verify_in_logs $SUCCESS_TIMEOUT $LOCALE
verify_in_logs $SUCCESS_TIMEOUT $TZ
verify_in_logs $SUCCESS_TIMEOUT '+09:30 '
cleanup

LAPP_TIMEZONE=foo lapp_ run
verify_in_logs $SUCCESS_TIMEOUT 'Unsupported timezone'
cleanup

echo $'\nVerifying developer mode' >&2
lapp_ run --env MODE=dev
verify_in_logs $SUCCESS_TIMEOUT 'developer mode'

echo $'\nVerifying MODE check' >&2
! lapp_ env --log MODE=abc
verify_in_logs $SUCCESS_TIMEOUT 'Unknown mode'

cleanup

echo $'\nVerifying mode changes and abbreviations' >&2
LAPP_MODE=d lapp_ run
verify_in_logs $SUCCESS_TIMEOUT 'developer mode'
verify_in_logs $SUCCESS_TIMEOUT 'AH00094'
docker cp .travis/$(basename $MODE_TEST_URL) lapp:/var/www/localhost/public/
verify_cmd_success $SUCCESS_TIMEOUT curl -Is $MODE_TEST_URL >$TEMP_FILE
grep -q '^Server: Apache/.* PHP/.* OpenSSL/.*$' $TEMP_FILE \
    && grep -q '^X-Powered-By: PHP/.*$' $TEMP_FILE \
    || cat $TEMP_FILE

{ lapp_ env -l MODE=pr; sleep $PIPE_DELAY; } | grep -q -F 'production mode'
verify_cmd_success $FAILURE_TIMEOUT curl -Is $MODE_TEST_URL >$TEMP_FILE
! grep -q '^Server: Apache/' $TEMP_FILE \
    && grep -q -v '^X-Powered-By:' $TEMP_FILE \
    || cat $TEMP_FILE

echo $'\nVerifying developer mode with XDebug' >&2
{ lapp_ env -l MODE=x; sleep $PIPE_DELAY; } | grep -q -F 'developer mode with XDebug'
verify_cmd_success $SUCCESS_TIMEOUT curl -Is $MODE_TEST_URL >$TEMP_FILE
grep -q '^Server: Apache/.* PHP/.* OpenSSL/.*$' $TEMP_FILE \
    && grep -q '^X-Powered-By: PHP/.*$' $TEMP_FILE \
    || cat $TEMP_FILE

echo $'\nVerifying MODE persistence' >&2
{ lapp_ env -l PHP_foo=bar; sleep $PIPE_DELAY; } | grep -q -F 'developer mode with XDebug'

echo $'\nVerifying php.ini setting' >&2
verify_cmd_success $SUCCESS_TIMEOUT docker exec -it lapp cat /etc/php7/conf.d/zz_99_overrides.ini | grep -q -F 'foo="bar"'

echo $'\nVerifying settings precedence' >&2
{ LAPP_MODE=dev PHP_foo=xyz lapp_ env -l MODE=x PHP_foo=bar; sleep $PIPE_DELAY; } | grep -q -F 'developer mode with XDebug'
verify_cmd_success $SUCCESS_TIMEOUT docker exec -it lapp cat /etc/php7/conf.d/zz_99_overrides.ini | grep -q -F 'foo="bar"'

cleanup

echo $'\nVerifying setting, changing and unsetting of arbitrary variables'
lapp_ run
verify_in_logs $SUCCESS_TIMEOUT 'AH00094'

lapp_ env A=foo BC=bar DEF=baz
verify_cmd_success $SUCCESS_TIMEOUT docker exec -it lapp /bin/bash -c '. /root/.bashrc; export' | grep -q -F ' A="foo"'
verify_cmd_success $SUCCESS_TIMEOUT docker exec -it lapp /bin/bash -c '. /root/.bashrc; export' | grep -q -F ' BC="bar"'
verify_cmd_success $SUCCESS_TIMEOUT docker exec -it lapp /bin/bash -c '. /root/.bashrc; export' | grep -q -F ' DEF="baz"'

lapp_ env A=42 BC= DEF
verify_cmd_success $SUCCESS_TIMEOUT docker exec -it lapp /bin/bash -c '. /root/.bashrc; export' | grep -q -F ' A="42"'
verify_cmd_success $SUCCESS_TIMEOUT docker exec -it lapp /bin/bash -c '. /root/.bashrc; export' | grep -q -F ' BC=""'
! verify_cmd_success $FAILURE_TIMEOUT docker exec -it lapp /bin/bash -c '. /root/.bashrc; export' | grep -q -F ' DEF='

cleanup


# Test certificates
echo $'\n*************** Certificates' >&2
HOST_NAME=dev.under.test
CERTFILE='/tmp/test-cert'
CN=foo.bar

echo $'\nVerifying self-signed certificate' >&2
lapp_ run -H $HOST_NAME
verify_in_logs $SUCCESS_TIMEOUT "CN=$HOST_NAME"
cleanup

echo $'\nVerifying custom certificate' >&2
openssl genrsa -out "$CERTFILE.key" 2048 2>/dev/null
openssl req -new -sha256 -out "$CERTFILE.csr" -key "$CERTFILE.key" -subj "/CN=$CN" 2>/dev/null
openssl x509 -req -days 1 -in "$CERTFILE.csr" -signkey "$CERTFILE.key" -out "$CERTFILE.pem" -outform PEM 2>/dev/null

lapp_ run
verify_in_logs $SUCCESS_TIMEOUT 'AH00094'
docker cp "$CERTFILE.key" lapp:/var/www/localhost/.certs/default.key
docker exec lapp /bin/bash -c 'chmod 600 /var/www/localhost/.certs/default.key'
docker cp "$CERTFILE.pem" lapp:/var/www/localhost/.certs/default.pem
docker exec lapp /bin/bash -c 'chmod 644 /var/www/localhost/.certs/default.pem'
lapp_ env

verify_cmd_success $SUCCESS_TIMEOUT curl -Isk $README_URL_SECURE | grep -q '200 OK'
echo | \
    openssl s_client -showcerts -servername -connect $HOST_IP:$HTTPS_PORT 2>/dev/null | \
        grep -q -F "subject=CN = $CN"
cleanup


# Remove trap
trap - EXIT

# If we have arrived here then exit successfully
echo $'\n*************** All tests have passed\n' >&2
exit 0

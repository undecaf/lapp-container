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

# Generates a private key and a certificate with $1 as CN and
# installs them with $2 as basename in $VHOSTS_CONF_DIR of container
# $3 (defaults to 'lapp').
deploy_cert() {
    local KEY_FILE=$(mktemp)
    local CSR_FILE=$(mktemp)
    local PEM_FILE=$(mktemp)

    openssl genrsa -out $KEY_FILE 2048 2>/dev/null
    openssl req -new -sha256 -out $CSR_FILE -key $KEY_FILE -subj "/CN=$1" 2>/dev/null
    openssl x509 -req -days 1 -in $CSR_FILE -signkey $KEY_FILE -out $PEM_FILE -outform PEM 2>/dev/null

    docker cp $KEY_FILE lapp:$VHOSTS_CONF_DIR/$2.key
    docker exec "${3:-lapp}" /bin/bash -c "chmod 600 $VHOSTS_CONF_DIR/$2.key"
    docker cp $PEM_FILE lapp:$VHOSTS_CONF_DIR/$2.pem
    docker exec "${3:-lapp}" /bin/bash -c "chmod 644 $VHOSTS_CONF_DIR/$2.pem; chown apache: $VHOSTS_CONF_DIR/$2."'{key,pem}'

    rm -f $KEY_FILE $CSR_FILE $PEM_FILE
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

WWW_VOL=/var/www/www-vol
VHOSTS_CONF_DIR=$WWW_VOL/conf.d
DEFAULT_VHOST=localhost
DEFAULT_DOCROOT=$WWW_VOL/$DEFAULT_VHOST/public
DEFAULT_CERT=$VHOSTS_CONF_DIR/$DEFAULT_VHOST

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
docker cp .travis/$(basename $SYNTAX_ERR_URL) lapp:$DEFAULT_DOCROOT/
verify_cmd_success $SUCCESS_TIMEOUT curl -Is $SYNTAX_ERR_URL | grep -q '500 Internal Server Error'
verify_in_logs $SUCCESS_TIMEOUT 'PHP Parse error'

docker cp .travis/$(basename $RUNTIME_ERR_URL) lapp:$DEFAULT_DOCROOT/
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
TEST_WWW_VOL='./www-volume/test-www'
TEST_PG_VOL="$(readlink -f .)/postgres volume/test-pg"
TEST_DOCROOT="$TEST_WWW_VOL/$DEFAULT_VHOST/public"
TEST_VHOSTS_CONF_DIR=$TEST_WWW_VOL/$(basename $VHOSTS_CONF_DIR)

echo $'\nTesting volume names and persistence' >&2
LAPP_WWW_VOL=$(basename "$TEST_WWW_VOL") lapp_ run -V $(basename "$TEST_PG_VOL")
verify_volumes_exist $(basename "$TEST_WWW_VOL") $(basename "$TEST_PG_VOL")
verify_in_logs $SUCCESS_TIMEOUT 'SSL certificate'
FINGERPRINT="$(docker exec lapp openssl x509 -noout -in $DEFAULT_CERT.pem -fingerprint -sha256)"

lapp_ stop --rm -t 1
LAPP_WWW_VOL=$(basename "$TEST_WWW_VOL") lapp_ run -V $(basename "$TEST_PG_VOL")
verify_in_logs $SUCCESS_TIMEOUT 'SSL certificate'
test "$FINGERPRINT" = "$(docker exec lapp openssl x509 -noout -in $DEFAULT_CERT.pem -fingerprint -sha256)"

cleanup

echo $'\nTesting bind-mounted volumes and persistence' >&2
LAPP_PG_VOL="$TEST_PG_VOL" lapp_ run -v "$TEST_WWW_VOL"

verify_cmd_success $SUCCESS_TIMEOUT sudo test -f "$TEST_DOCROOT/index.html"
! sudo test -O "$TEST_DOCROOT/index.html"
! sudo test -G "$TEST_DOCROOT/index.html"

verify_cmd_success $SUCCESS_TIMEOUT sudo test -f "$TEST_PG_VOL/PG_VERSION"
! sudo test -O "$TEST_PG_VOL/PG_VERSION"
! sudo test -G "$TEST_PG_VOL/PG_VERSION"

verify_in_logs $SUCCESS_TIMEOUT 'SSL certificate'
FINGERPRINT="$(sudo openssl x509 -noout -in "$TEST_VHOSTS_CONF_DIR/$DEFAULT_VHOST.pem" -fingerprint -sha256)"

lapp_ stop --rm -t 1
LAPP_PG_VOL="$TEST_PG_VOL" lapp_ run -v "$TEST_WWW_VOL"
verify_in_logs $SUCCESS_TIMEOUT 'SSL certificate'
test "$FINGERPRINT" = "$(sudo openssl x509 -noout -in "$TEST_VHOSTS_CONF_DIR/$DEFAULT_VHOST.pem" -fingerprint -sha256)"

cleanup
sudo rm -rf "$TEST_WWW_VOL" "$TEST_PG_VOL"

echo $'\nTesting bind-mounted volume ownership and persistence' >&2
lapp_ run -v "$TEST_WWW_VOL" -o -V "$TEST_PG_VOL" -O

verify_cmd_success $SUCCESS_TIMEOUT test -f "$TEST_DOCROOT/index.html"
test -O "$TEST_DOCROOT/index.html"
test -G "$TEST_DOCROOT/index.html"

verify_cmd_success $SUCCESS_TIMEOUT test -f "$TEST_PG_VOL/PG_VERSION"
test -O "$TEST_PG_VOL/PG_VERSION"
test -G "$TEST_PG_VOL/PG_VERSION"

verify_in_logs $SUCCESS_TIMEOUT 'SSL certificate'
FINGERPRINT="$(openssl x509 -noout -in "$TEST_VHOSTS_CONF_DIR/$DEFAULT_VHOST.pem" -fingerprint -sha256)"

lapp_ stop --rm -t 1
lapp_ run -v "$TEST_WWW_VOL" -o -V "$TEST_PG_VOL" -O
verify_in_logs $SUCCESS_TIMEOUT 'SSL certificate'
test "$FINGERPRINT" = "$(openssl x509 -noout -in "$TEST_VHOSTS_CONF_DIR/$DEFAULT_VHOST.pem" -fingerprint -sha256)"

cleanup
rm -rf "$TEST_WWW_VOL" "$TEST_PG_VOL"


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
docker cp .travis/$(basename $MODE_TEST_URL) lapp:$DEFAULT_DOCROOT/
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
verify_cmd_success $SUCCESS_TIMEOUT docker exec -it lapp cat /etc/php${MAJOR_VERSION}/conf.d/zz_99_overrides.ini | grep -q -F 'foo="bar"'

echo $'\nVerifying settings precedence' >&2
{ LAPP_MODE=dev PHP_foo=xyz lapp_ env -l MODE=x PHP_foo=bar; sleep $PIPE_DELAY; } | grep -q -F 'developer mode with XDebug'
verify_cmd_success $SUCCESS_TIMEOUT docker exec -it lapp cat /etc/php${MAJOR_VERSION}/conf.d/zz_99_overrides.ini | grep -q -F 'foo="bar"'

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
CN=foo.bar

echo $'\nVerifying self-signed certificate' >&2
lapp_ run -H $HOST_NAME
verify_in_logs $SUCCESS_TIMEOUT "CN=$HOST_NAME"
cleanup

echo $'\nVerifying custom certificate' >&2
lapp_ run
verify_in_logs $SUCCESS_TIMEOUT 'AH00094'
deploy_cert $CN $DEFAULT_VHOST
lapp_ env

verify_cmd_success $SUCCESS_TIMEOUT curl -Isk $README_URL_SECURE | grep -q '200 OK'
echo | \
    openssl s_client -showcerts -servername -connect $HOST_IP:$HTTPS_PORT 2>/dev/null | \
        grep -q -F "subject=CN = $CN"
cleanup


# Virtual hosts
echo $'\n*************** Virtual hosts\n' >&2
HOST_NAME=dev.test
VHOST=test-vhost
CN=$VHOST.$HOST_NAME
CONTENT=$(openssl rand -hex 12)

lapp_ run -H $HOST_NAME
verify_in_logs $SUCCESS_TIMEOUT 'AH00094'
docker cp lapp:$VHOSTS_CONF_DIR/vhost.conf.template /tmp/$VHOST.conf
sed -e 's/Define VHOST_SUBDOMAIN .*/Define VHOST_SUBDOMAIN '$VHOST/ -i /tmp/$VHOST.conf
docker cp /tmp/$VHOST.conf lapp:$VHOSTS_CONF_DIR/$VHOST.conf
docker exec lapp /bin/bash -c "mkdir -p $WWW_VOL/$VHOST/public; echo $CONTENT >$WWW_VOL/$VHOST/public/index.html"
docker exec lapp /bin/bash -c "chown -R apache: $WWW_VOL/$VHOST $VHOSTS_CONF_DIR"

deploy_cert $CN $VHOST
lapp_ env

verify_cmd_success $SUCCESS_TIMEOUT curl -s -H "Host: $CN" http://$HOST_IP:$HTTP_PORT/ | grep -q -F $CONTENT

cleanup
rm -f /tmp/$VHOST.conf


# Remove trap
trap - EXIT

# If we have arrived here then exit successfully
echo $'\n*************** All tests have passed\n' >&2
exit 0

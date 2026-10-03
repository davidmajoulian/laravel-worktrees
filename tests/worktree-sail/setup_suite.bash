# Builds one throwaway Sail project for the whole suite and starts its shared
# services once: a clone of this repository whose compose.yaml adds Valkey and
# RustFS, on a port band, Compose project name and image name of its own so it can
# run next to real projects on the same machine. teardown_suite removes all of it.
#
# The fixture lives under a path with a space in it, so every test also proves the
# tooling copes with one.

setup_suite() {
    # [[ ]] only fails a bats test under bash 4.1 or later.
    [ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "run the suite with bash 4 or later" >&2; return 1; }

    export REPO_ROOT
    REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)
    local parent
    parent=$(mktemp -d "${TMPDIR:-/tmp}/wts suite.XXXXXX") || return 1
    [ -d "$parent" ] || return 1
    export FIXTURE_PARENT
    FIXTURE_PARENT=$(cd "$parent" && pwd -P) || return 1
    export FIXTURE="$FIXTURE_PARENT/app"
    export FIXTURE_PROJECT="wtstest$$"
    export WTS_FIXTURE_IMAGE="wtstest$$/app"
    export WWWUSER="${WWWUSER:-$(id -u)}" WWWGROUP="${WWWGROUP:-$(id -g)}"

    [ -d "$REPO_ROOT/vendor/laravel/sail" ] \
        || { echo "run 'composer install' in $REPO_ROOT first" >&2; return 1; }

    # The working-tree copy of the tooling is what is under test, not the last
    # commit, so it is laid over a clone and committed there: `git worktree add`
    # only hands a new worktree what is committed.
    git clone --quiet "$REPO_ROOT" "$FIXTURE"
    cp "$REPO_ROOT/bin/worktree-sail" "$FIXTURE/bin/worktree-sail"
    cp "$REPO_ROOT/sail" "$REPO_ROOT/compose.worktree.yaml" "$FIXTURE/"
    [ ! -f "$REPO_ROOT/compose.override.yaml" ] || cp "$REPO_ROOT/compose.override.yaml" "$FIXTURE/"
    cp "$BATS_TEST_DIRNAME/fixture/compose.yaml" "$FIXTURE/compose.yaml"
    cp -Rc "$REPO_ROOT/vendor" "$FIXTURE/vendor" 2>/dev/null || cp -R "$REPO_ROOT/vendor" "$FIXTURE/vendor"

    write_fixture_env "$FIXTURE/.env"

    # An origin whose default branch is `dev`, so `create` has something other
    # than `main` to discover.
    git init --quiet --bare --initial-branch=dev "$FIXTURE_PARENT/origin.git"
    (
        cd "$FIXTURE" || exit 1
        git checkout --quiet -B dev
        git add -A
        git -c user.name=test -c user.email=test@example.com commit --quiet -m fixture --allow-empty
        git remote set-url origin "$FIXTURE_PARENT/origin.git"
        git push --quiet -u origin dev
        git remote set-head origin --delete >/dev/null 2>&1 || true
        git fetch --quiet --prune origin
    )

    ( cd "$FIXTURE" || exit 1; docker compose up -d --wait pgsql valkey rustfs mailpit >/dev/null 2>&1 \
        || docker compose up -d pgsql valkey rustfs mailpit >/dev/null )
    wait_for_rustfs
}

teardown_suite() {
    local ids
    [ -n "${FIXTURE_PROJECT:-}" ] || return 0
    # Every container, network and volume of the fixture's project or one of its
    # worktrees ("<project>-wt-..."), matched exactly, never by a bare prefix that
    # another run's project could share.
    ids=$(docker ps -a --filter "label=com.docker.compose.project" \
        --format '{{.ID}} {{.Label "com.docker.compose.project"}}' \
        | awk -v p="$FIXTURE_PROJECT" '$2 == p || index($2, p "-") == 1 { print $1 }')
    [ -z "$ids" ] || docker rm -fv $ids >/dev/null 2>&1 || true
    ids=$(docker network ls --format '{{.ID}} {{.Name}}' \
        | awk -v p="$FIXTURE_PROJECT" 'index($2, p "_") == 1 || index($2, p "-") == 1 { print $1 }')
    [ -z "$ids" ] || docker network rm $ids >/dev/null 2>&1 || true
    ids=$(docker volume ls --format '{{.Name}}' \
        | awk -v p="$FIXTURE_PROJECT" 'index($1, p "_") == 1 || index($1, p "-") == 1')
    [ -z "$ids" ] || docker volume rm -f $ids >/dev/null 2>&1 || true
    docker image rm "$WTS_FIXTURE_IMAGE" >/dev/null 2>&1 || true
    # Only ever the directory setup_suite made.
    case "${FIXTURE_PARENT:-}" in
        */"wts suite."*) rm -rf "$FIXTURE_PARENT" ;;
    esac
}

write_fixture_env() { # <file>
    cat > "$1" <<EOF
APP_NAME=WorktreeSailTest
APP_ENV=local
APP_KEY=base64:$(openssl rand -base64 32)
APP_DEBUG=true
APP_URL=http://localhost:18080
COMPOSE_PROJECT_NAME=$FIXTURE_PROJECT
APP_PORT=18080
VITE_PORT=15173
WORKTREE_APP_PORT_BASE=18081
WORKTREE_VITE_PORT_BASE=15174
FORWARD_DB_PORT=15432
FORWARD_VALKEY_PORT=16379
FORWARD_RUSTFS_PORT=19000
FORWARD_RUSTFS_CONSOLE_PORT=19001
FORWARD_MAILPIT_PORT=11025
FORWARD_MAILPIT_DASHBOARD_PORT=18025
DB_CONNECTION=pgsql
DB_HOST=pgsql
DB_PORT=5432
DB_DATABASE=laravel
DB_USERNAME=sail
DB_PASSWORD=password
SESSION_DRIVER=database
QUEUE_CONNECTION=redis
CACHE_STORE=redis
REDIS_CLIENT=phpredis
REDIS_HOST=valkey
REDIS_PORT=6379
MAIL_MAILER=smtp
MAIL_HOST=mailpit
MAIL_PORT=1025
AWS_ACCESS_KEY_ID=sail
AWS_SECRET_ACCESS_KEY=password
AWS_DEFAULT_REGION=us-east-1
AWS_ENDPOINT=http://rustfs:9000
AWS_USE_PATH_STYLE_ENDPOINT=true
AWS_BUCKET=local-private
AWS_PUBLIC_BUCKET=local-public
WORKTREE_BUCKETS="AWS_BUCKET AWS_PUBLIC_BUCKET"
WORKTREE_PUBLIC_BUCKETS="AWS_PUBLIC_BUCKET"
WORKTREE_LOCK_TIMEOUT=20
EOF
}

wait_for_rustfs() {
    local i=0
    while [ "$i" -lt 60 ]; do
        curl -s -o /dev/null "http://localhost:19000/health" && return 0
        sleep 1; i=$((i + 1))
    done
    echo "rustfs did not come up" >&2
    return 1
}

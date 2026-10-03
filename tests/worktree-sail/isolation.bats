#!/usr/bin/env bats
# Two worktrees sharing one set of services: each owns its databases, keys and
# buckets, and tearing one down never touches the other, the main checkout, or
# the shared containers.

load helpers

setup() {
    A=$(add_worktree iso-a)
    B=$(add_worktree iso-b)
    wts "$A" prepare >/dev/null
    wts "$B" prepare >/dev/null
}

teardown() {
    cleanup_worktree iso-a
    cleanup_worktree iso-b
}

@test "each worktree gets its own database, test database, key prefixes and buckets" {
    local k
    for k in DB_DATABASE REDIS_PREFIX CACHE_PREFIX AWS_BUCKET AWS_PUBLIC_BUCKET APP_PORT VITE_PORT COMPOSE_PROJECT_NAME; do
        [ -n "$(env_of "$A" "$k")" ]
        [ "$(env_of "$A" "$k")" != "$(env_of "$B" "$k")" ]
        [ "$(env_of "$A" "$k")" != "$(env_of "$FIXTURE" "$k")" ]
    done
    database_exists "$(env_of "$A" DB_DATABASE)"
    database_exists "$(env_of "$A" DB_DATABASE)_testing"
}

@test "destroy flushes the worktree's keys in every logical database and leaves the other's" {
    local pa pb
    pa=$(env_of "$A" REDIS_PREFIX); pb=$(env_of "$B" REDIS_PREFIX)
    valkey -n 0 SET "${pa}queue" 1 >/dev/null
    valkey -n 1 SET "$(env_of "$A" CACHE_PREFIX)entry" 1 >/dev/null
    valkey -n 1 SET "${pa}spaced key" 1 >/dev/null
    valkey -n 0 SET "${pb}queue" 1 >/dev/null
    valkey -n 1 SET "$(env_of "$B" CACHE_PREFIX)entry" 1 >/dev/null

    run wts "$A" destroy
    [ "$status" -eq 0 ]

    [ "$(valkey -n 0 EXISTS "${pa}queue")" = 0 ]
    [ "$(valkey -n 1 EXISTS "$(env_of "$A" CACHE_PREFIX)entry")" = 0 ]
    [ "$(valkey -n 1 EXISTS "${pa}spaced key")" = 0 ]
    [ "$(valkey -n 0 EXISTS "${pb}queue")" = 1 ]
    [ "$(valkey -n 1 EXISTS "$(env_of "$B" CACHE_PREFIX)entry")" = 1 ]
}

@test "destroy drops the worktree's databases, its parallel-test ones included, and nothing else" {
    local adb tdb
    adb=$(env_of "$A" DB_DATABASE); tdb="${adb}_testing"
    psql_q "CREATE DATABASE \"${tdb}_test_1\"" >/dev/null
    psql_q "CREATE DATABASE \"${tdb}_test_2\"" >/dev/null

    run wts "$A" destroy
    [ "$status" -eq 0 ]

    refute database_exists "$adb"
    refute database_exists "$tdb"
    refute database_exists "${tdb}_test_1"
    refute database_exists "${tdb}_test_2"
    database_exists "$(env_of "$B" DB_DATABASE)"
    database_exists "$(env_of "$B" DB_DATABASE)_testing"
    database_exists laravel
    database_exists testing
}

@test "destroy drops the extra databases named by WORKTREE_EXTRA_DATABASE_SUFFIXES" {
    local adb
    adb=$(env_of "$A" DB_DATABASE)
    psql_q "CREATE DATABASE \"${adb}_pages_testing\"" >/dev/null
    printf 'WORKTREE_EXTRA_DATABASE_SUFFIXES=_pages_testing\n' >> "$FIXTURE/.env"

    run wts "$A" destroy
    sed -i.bak '/^WORKTREE_EXTRA_DATABASE_SUFFIXES=/d' "$FIXTURE/.env" && rm -f "$FIXTURE/.env.bak"
    [ "$status" -eq 0 ]
    refute database_exists "${adb}_pages_testing"
}

@test "destroy never stops or recreates the shared services" {
    local before after
    before=$(for s in pgsql valkey rustfs mailpit; do container_of "$s"; done)
    run wts "$A" destroy
    [ "$status" -eq 0 ]
    after=$(for s in pgsql valkey rustfs mailpit; do container_of "$s"; done)
    [ "$before" = "$after" ]
}

@test "destroy starts a stopped shared service rather than leaving state behind" {
    local pa pb
    pa=$(env_of "$A" REDIS_PREFIX); pb=$(env_of "$B" REDIS_PREFIX)
    valkey SET "${pa}left" 1 >/dev/null
    valkey SET "${pb}control" 1 >/dev/null
    valkey SAVE >/dev/null
    ( cd "$FIXTURE" && docker compose stop valkey >/dev/null 2>&1 )

    run wts "$A" destroy
    [ "$status" -eq 0 ]
    [ -n "$(container_of valkey)" ]
    # B's key coming back proves the data survived the restart, so A's key being
    # gone means teardown flushed it rather than the restart losing it.
    [ "$(valkey EXISTS "${pb}control")" = 1 ]
    [ "$(valkey EXISTS "${pa}left")" = 0 ]
}

@test "destroy fails, naming what is left, when it cannot drop a database" {
    sed -i.bak 's/^DB_USERNAME=.*/DB_USERNAME=nobody/' "$A/.env" && rm -f "$A/.env.bak"

    run wts "$A" destroy
    [ "$status" -ne 0 ]
    [[ "$output" == *"still has"* ]]
    [[ "$output" == *"$(env_of "$A" DB_DATABASE)"* ]]
}

@test "a worktree's key prefix is never the start of another worktree's" {
    local foo foocache pf pfc
    foo=$(add_worktree foo); foocache=$(add_worktree foo-cache)
    wts "$foo" prepare >/dev/null; wts "$foocache" prepare >/dev/null
    pf=$(env_of "$foo" REDIS_PREFIX); pfc=$(env_of "$foocache" REDIS_PREFIX)
    [[ "$pfc" != "$pf"* ]]
    [[ "$(env_of "$foocache" CACHE_PREFIX)" != "$(env_of "$foo" CACHE_PREFIX)"* ]]
    valkey SET "${pfc}queue" 1 >/dev/null

    run wts "$foo" destroy
    [ "$status" -eq 0 ]
    [ "$(valkey EXISTS "${pfc}queue")" = 1 ]
    cleanup_worktree foo; cleanup_worktree foo-cache
}

@test "a .env copied from a sibling worktree is replaced, and destroying the copy spares the sibling" {
    local c
    c=$(add_worktree iso-c)
    cp "$A/.env" "$c/.env"

    run wts "$c" prepare
    [ "$status" -eq 0 ]
    [ "$(env_of "$c" DB_DATABASE)" != "$(env_of "$A" DB_DATABASE)" ]
    [ "$(env_of "$c" COMPOSE_PROJECT_NAME)" != "$(env_of "$A" COMPOSE_PROJECT_NAME)" ]
    [ "$(env_of "$c" APP_PORT)" != "$(env_of "$A" APP_PORT)" ]

    cp "$A/.env" "$c/.env"
    run wts "$c" destroy
    database_exists "$(env_of "$A" DB_DATABASE)"
    bucket_exists "$(env_of "$A" AWS_BUCKET)"
    cleanup_worktree iso-c
}

@test "worktree projects are named <main>-wt-<folder>, and a real project sharing the old style of name is never swept" {
    local v1 foreign
    [ "$(env_of "$A" COMPOSE_PROJECT_NAME)" = "${FIXTURE_PROJECT}-wt-iso-a" ]
    foreign=$(docker run -d --label "com.docker.compose.project=${FIXTURE_PROJECT}-v1" \
        --init "$STANDIN_IMAGE" sleep 300)
    v1=$(add_worktree v1)
    wts "$v1" prepare >/dev/null

    run wts "$v1" destroy
    [ "$status" -eq 0 ]
    [ -n "$(docker ps -q --filter "id=$foreign")" ]
    docker rm -f "$foreign" >/dev/null
    cleanup_worktree v1
}

@test "folders that reduce to the same names are refused, not merged" {
    local first second
    first=$(add_worktree v1.2); second=$(add_worktree v1-2)
    wts "$first" init >/dev/null
    run wts "$second" init
    [ "$status" -ne 0 ]
    [[ "$output" == *"v1.2 already uses"* ]]
    cleanup_worktree v1.2; cleanup_worktree v1-2
}

@test "long folder names that share their start still get different databases and buckets" {
    local one two stem=feature-a-very-long-branch-name-that-shares-its-first-sixty-characters
    one=$(add_worktree "${stem}-one"); two=$(add_worktree "${stem}-two")
    wts "$one" init >/dev/null; wts "$two" init >/dev/null
    [ "$(env_of "$one" DB_DATABASE)" != "$(env_of "$two" DB_DATABASE)" ]
    [ "$(env_of "$one" AWS_BUCKET)" != "$(env_of "$two" AWS_BUCKET)" ]
    [ "$(env_of "$one" AWS_PUBLIC_BUCKET)" != "$(env_of "$two" AWS_PUBLIC_BUCKET)" ]
    local db
    db=$(env_of "$one" DB_DATABASE)
    [ "${#db}" -le 47 ]
    cleanup_worktree "${stem}-one"; cleanup_worktree "${stem}-two"
}

@test "values with spaces are written so Laravel, Compose and Sail all read them back" {
    # The fixture lives under ".../wts suite.XXXX/", so SAIL_GIT_COMMON_DIR has a space.
    [[ "$(grep '^SAIL_GIT_COMMON_DIR=' "$A/.env")" == "SAIL_GIT_COMMON_DIR='"*"'" ]]
    run bash -c "set -a; . '$A/.env'; printf '%s' \"\$SAIL_GIT_COMMON_DIR\""
    [ "$output" = "$FIXTURE/.git" ]
}

@test "a worktree set up by an older version is adopted under the names it already has" {
    local old
    old=$(add_worktree legacy1)
    {
        printf 'SAIL_FILES=compose.worktree.yaml\n'
        printf 'COMPOSE_PROJECT_NAME=%s-legacy1\n' "$FIXTURE_PROJECT"
        printf 'DB_DATABASE=laravel_legacy1\n'
        printf 'REDIS_PREFIX=legacy1_database_\n'
        printf 'CACHE_PREFIX=legacy1_cache_\n'
        printf 'AWS_BUCKET=legacy1\n'
        printf 'AWS_PUBLIC_BUCKET=legacy1-public\n'
    } >> "$old/.env"

    run wts "$old" init
    [ "$status" -eq 0 ]
    [ "$(env_of "$old" COMPOSE_PROJECT_NAME)" = "${FIXTURE_PROJECT}-legacy1" ]
    [ "$(env_of "$old" DB_DATABASE)" = laravel_legacy1 ]
    [ "$(env_of "$old" REDIS_PREFIX)" = legacy1_database_ ]
    [ "$(env_of "$old" WORKTREE_SAIL_ROOT)" = "$old" ]
    [ -n "$(env_of "$old" SAIL_GIT_COMMON_DIR)" ]

    # Re-running init keeps them too.
    wts "$old" init >/dev/null
    [ "$(env_of "$old" DB_DATABASE)" = laravel_legacy1 ]
    cleanup_worktree legacy1
}

@test "tearing down a legacy worktree never touches a real project that shares its old name" {
    local v9 foreign volume
    v9=$(add_worktree v9)
    printf 'SAIL_FILES=compose.worktree.yaml\nCOMPOSE_PROJECT_NAME=%s-v9\n' "$FIXTURE_PROJECT" >> "$v9/.env"
    volume=$(docker volume create --label "com.docker.compose.project=${FIXTURE_PROJECT}-v9" "${FIXTURE_PROJECT}-v9_data")
    foreign=$(docker run -d -v "$volume:/data" \
        --label "com.docker.compose.project=${FIXTURE_PROJECT}-v9" \
        --label "com.docker.compose.project.working_dir=/somewhere/else" \
        --init "$STANDIN_IMAGE" sleep 300)

    # Stopped, so Docker itself would let the volume go: only the tool's own
    # restraint keeps it.
    docker stop -t 1 "$foreign" >/dev/null
    run wts "$v9" destroy
    [ -n "$(docker ps -aq --filter "id=$foreign")" ]
    docker volume inspect "$volume" >/dev/null
    docker rm -f "$foreign" >/dev/null; docker volume rm "$volume" >/dev/null
    cleanup_worktree v9
}

@test "destroy leaves every database alone when the worktree's is the main checkout's" {
    local w
    w=$(add_worktree samedb)
    wts "$w" init >/dev/null
    sed -i.bak 's/^DB_DATABASE=.*/DB_DATABASE=laravel/' "$w/.env" && rm -f "$w/.env.bak"
    psql_q 'CREATE DATABASE "laravel_testing"' >/dev/null

    run wts "$w" destroy
    database_exists laravel
    database_exists laravel_testing
    psql_q 'DROP DATABASE "laravel_testing"' >/dev/null
    cleanup_worktree samedb
}

@test "a folder name with no letters or digits is refused" {
    local w="$FIXTURE/.claude/worktrees/---"
    git -C "$FIXTURE" worktree add --quiet -b test/dashes "$w" dev
    run bash -c "cd '$w' && ./bin/worktree-sail init"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no letters or digits"* ]]
    git -C "$FIXTURE" worktree remove --force "$w"
    git -C "$FIXTURE" branch -D test/dashes >/dev/null
}

@test "the ./sail shim configures a worktree whose .env was copied from a sibling" {
    local c
    c=$(add_worktree shim-c)
    cp "$A/.env" "$c/.env"
    run bash -c "cd '$c' && sh ./sail ps -q"
    [ "$(env_of "$c" WORKTREE_SAIL_ROOT)" = "$c" ]
    [ "$(env_of "$c" COMPOSE_PROJECT_NAME)" != "$(env_of "$A" COMPOSE_PROJECT_NAME)" ]
    cleanup_worktree shim-c
}

@test "tearing down a legacy worktree never removes a stopped project's volumes that share its old name" {
    local v8 volume
    v8=$(add_worktree v8)
    printf 'SAIL_FILES=compose.worktree.yaml\nCOMPOSE_PROJECT_NAME=%s-v8\n' "$FIXTURE_PROJECT" >> "$v8/.env"
    # A stopped project keeps its volumes and has no containers.
    volume=$(docker volume create --label "com.docker.compose.project=${FIXTURE_PROJECT}-v8" "${FIXTURE_PROJECT}-v8_data")
    # Our own container under that name, run from the worktree's folder.
    docker run -d --label "com.docker.compose.project=${FIXTURE_PROJECT}-v8" \
        --label "com.docker.compose.project.working_dir=$v8" --init "$STANDIN_IMAGE" sleep 300 >/dev/null

    run wts "$v8" destroy
    docker volume inspect "$volume" >/dev/null
    [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=${FIXTURE_PROJECT}-v8")" ]
    docker volume rm "$volume" >/dev/null
    cleanup_worktree v8
}

@test "a worktree set up before the project had S3 gets its own buckets on the next init" {
    local w
    w=$(add_worktree pre-s3)
    wts "$w" init >/dev/null
    # What a worktree configured without S3 holds: the main checkout's bucket values.
    sed -i.bak -e "s/^AWS_BUCKET=.*/AWS_BUCKET=local-private/" -e "s/^AWS_PUBLIC_BUCKET=.*/AWS_PUBLIC_BUCKET=local-public/" "$w/.env" && rm -f "$w/.env.bak"

    run wts "$w" init
    [ "$status" -eq 0 ]
    [ "$(env_of "$w" AWS_BUCKET)" = pre-s3 ]
    [ "$(env_of "$w" AWS_PUBLIC_BUCKET)" = pre-s3-public ]
    cleanup_worktree pre-s3
}

@test "teardown of a legacy worktree whose folder is gone removes its container, old database and old keys" {
    local path="$FIXTURE/.claude/worktrees/legacy3" container
    container=$(docker run -d --label "com.docker.compose.project=${FIXTURE_PROJECT}-legacy3" \
        --label "com.docker.compose.project.working_dir=$path" --init "$STANDIN_IMAGE" sleep 300)
    psql_q 'CREATE DATABASE "laravel_legacy3"' >/dev/null
    valkey SET legacy3_database_queue 1 >/dev/null
    valkey -n 1 SET legacy3_cache_entry 1 >/dev/null

    run bash -c "cd '$FIXTURE' && ./bin/worktree-sail teardown '$path'"
    [ "$status" -eq 0 ]
    [ -z "$(docker ps -aq --filter "id=$container")" ]
    refute database_exists laravel_legacy3
    [ "$(valkey EXISTS legacy3_database_queue)" = 0 ]
    [ "$(valkey -n 1 EXISTS legacy3_cache_entry)" = 0 ]
}

@test "a folder whose extra database would be the main checkout's own is refused" {
    local w
    w=$(add_worktree pages-testing)
    printf 'WORKTREE_EXTRA_DATABASE_SUFFIXES=_pages_testing\n' >> "$FIXTURE/.env"
    run wts "$w" init
    sed -i.bak '/^WORKTREE_EXTRA_DATABASE_SUFFIXES=/d' "$FIXTURE/.env" && rm -f "$FIXTURE/.env.bak"
    [ "$status" -ne 0 ]
    [[ "$output" == *"laravel_pages_testing' belongs to another checkout"* ]]
    cleanup_worktree pages-testing
}

@test "removing a folder whose derived names are the main checkout's never drops its databases" {
    local d="$FIXTURE/.claude/worktrees/pages-testing"
    printf 'WORKTREE_EXTRA_DATABASE_SUFFIXES=_pages_testing\n' >> "$FIXTURE/.env"
    psql_q 'CREATE DATABASE "laravel_pages_testing"' >/dev/null
    git -C "$FIXTURE" worktree add --quiet -b test/pages-testing "$d" dev
    cp "$FIXTURE/.env" "$d/.env"

    run bash -c "cd '$FIXTURE' && ./bin/worktree-sail remove pages-testing --branch"
    sed -i.bak '/^WORKTREE_EXTRA_DATABASE_SUFFIXES=/d' "$FIXTURE/.env" && rm -f "$FIXTURE/.env.bak"
    database_exists laravel_pages_testing
    psql_q 'DROP DATABASE "laravel_pages_testing"' >/dev/null
    cleanup_worktree pages-testing
}

@test "a worktree whose test database would be the main checkout's extra is refused" {
    local w
    w=$(add_worktree pages)
    printf 'WORKTREE_EXTRA_DATABASE_SUFFIXES=_pages_testing\n' >> "$FIXTURE/.env"
    run wts "$w" init
    sed -i.bak '/^WORKTREE_EXTRA_DATABASE_SUFFIXES=/d' "$FIXTURE/.env" && rm -f "$FIXTURE/.env.bak"
    [ "$status" -ne 0 ]
    [[ "$output" == *"laravel_pages_testing' belongs to another checkout"* ]]
    cleanup_worktree pages
}

@test "a worktree whose database would be another worktree's test database is refused" {
    local one two
    one=$(add_worktree mail); two=$(add_worktree mail-testing)
    wts "$one" init >/dev/null
    run wts "$two" init
    [ "$status" -ne 0 ]
    [[ "$output" == *"belongs to another checkout"* ]]
    cleanup_worktree mail; cleanup_worktree mail-testing
}

@test "init never writes through a .env that is a symlink to the main checkout's" {
    local w before
    w=$(add_worktree linked)
    rm "$w/.env"; ln -s "$FIXTURE/.env" "$w/.env"
    before=$(cksum < "$FIXTURE/.env")

    run wts "$w" init
    [ "$status" -eq 0 ]
    [ "$(cksum < "$FIXTURE/.env")" = "$before" ]
    [ ! -L "$w/.env" ]
    [ "$(env_of "$w" WORKTREE_SAIL_ROOT)" = "$w" ]
    cleanup_worktree linked
}

@test "under an older version's name, a container that does not prove it ran from this folder is left alone" {
    local v7 unlabelled
    v7=$(add_worktree v7)
    printf 'SAIL_FILES=compose.worktree.yaml\nCOMPOSE_PROJECT_NAME=%s-v7\n' "$FIXTURE_PROJECT" >> "$v7/.env"
    unlabelled=$(docker run -d --init --label "com.docker.compose.project=${FIXTURE_PROJECT}-v7" "$STANDIN_IMAGE" sleep 300)

    run wts "$v7" destroy
    [ -n "$(docker ps -q --filter "id=$unlabelled")" ]
    docker rm -f "$unlabelled" >/dev/null
    cleanup_worktree v7
}

@test "init never writes through a .env that is a hard link to the main checkout's" {
    local w before
    w=$(add_worktree hardlinked)
    rm "$w/.env"; ln "$FIXTURE/.env" "$w/.env"
    before=$(cksum < "$FIXTURE/.env")

    run wts "$w" init
    [ "$status" -eq 0 ]
    [ "$(cksum < "$FIXTURE/.env")" = "$before" ]
    [ "$(env_of "$w" WORKTREE_SAIL_ROOT)" = "$w" ]
    cleanup_worktree hardlinked
}

@test "a symlinked .env.testing is replaced, not written through" {
    local w target
    w=$(add_worktree linked-testing)
    target="$BATS_TEST_TMPDIR/elsewhere.env"
    printf 'UNTOUCHED=1\n' > "$target"
    ln -s "$target" "$w/.env.testing"

    run wts "$w" init
    [ "$status" -eq 0 ]
    [ "$(cat "$target")" = "UNTOUCHED=1" ]
    [ ! -L "$w/.env.testing" ]
    cleanup_worktree linked-testing
}

@test "a sqlite project's worktree gets no database name and can be set up again" {
    local w
    w=$(add_worktree lite)
    sed -i.bak 's/^DB_CONNECTION=.*/DB_CONNECTION=sqlite/' "$FIXTURE/.env" "$w/.env" && rm -f "$FIXTURE/.env.bak" "$w/.env.bak"

    run wts "$w" init
    local first=$status
    run wts "$w" init
    local second=$status
    sed -i.bak 's/^DB_CONNECTION=.*/DB_CONNECTION=pgsql/' "$FIXTURE/.env" && rm -f "$FIXTURE/.env.bak"
    [ "$first" -eq 0 ]
    [ "$second" -eq 0 ]
    [ "$(env_of "$w" DB_DATABASE)" = laravel ]
    cleanup_worktree lite
}

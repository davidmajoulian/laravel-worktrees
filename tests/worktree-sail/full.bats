#!/usr/bin/env bats
# End to end: `create` and `remove` with real application containers. The Sail
# image is built once in setup_file, so every create after the first is "warm".

load helpers

setup_file() {
    ( cd "$FIXTURE" && docker compose build laravel.test >/dev/null 2>&1 )
}

teardown() {
    local w
    for w in 90-alpha 91-beta 92-gamma 93-delta 94-epsilon 95-zeta 96-eta 97-load-testing 98-theta; do cleanup_worktree "$w"; done
    git -C "$FIXTURE" branch -D deps-base >/dev/null 2>&1 || true
    psql_q 'DROP DATABASE IF EXISTS "wts_canary" WITH (FORCE)' >/dev/null 2>&1 || true
    rm -rf "$FIXTURE/.claude/worktrees/rogue"
    sed -i.bak '/^WORKTREE_POST_CREATE=/d' "$FIXTURE/.env" && rm -f "$FIXTURE/.env.bak"
}

serving() { # <dir>
    [ "$(http_status "http://localhost:$(env_of "$1" APP_PORT)")" = 200 ]
}

@test "create branches from the repository's default branch into a folder named after the branch's last segment" {
    run bash -c "cd '$FIXTURE' && ./bin/worktree-sail create feature/90-alpha"
    [ "$status" -eq 0 ]
    local dir="$FIXTURE/.claude/worktrees/90-alpha"
    [ -d "$dir" ]
    [ "$(git -C "$dir" rev-parse --abbrev-ref HEAD)" = feature/90-alpha ]
    [ "$(git -C "$dir" rev-parse HEAD)" = "$(git -C "$FIXTURE" rev-parse origin/dev)" ]
    # No upstream: a plain `git push` must not target dev.
    refute git -C "$dir" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1
    serving "$dir"
    # Its lockfiles are main's, so the cloned dependencies stand.
    [[ "$output" != *"differs from the main checkout's"* ]]
}

@test "create installs the dependencies when its branch's lockfile differs from the main checkout's" {
    # A base branch whose composer.lock differs only in its content hash, so the
    # install finds every package already there and needs no network.
    local index blob tree commit
    index="$BATS_TEST_TMPDIR/index"
    blob=$(sed 's/"content-hash": "[^"]*"/"content-hash": "changed-by-the-test"/' "$FIXTURE/composer.lock" \
        | git -C "$FIXTURE" hash-object -w --stdin)
    GIT_INDEX_FILE=$index git -C "$FIXTURE" read-tree dev
    GIT_INDEX_FILE=$index git -C "$FIXTURE" update-index --cacheinfo "100644,$blob,composer.lock"
    tree=$(GIT_INDEX_FILE=$index git -C "$FIXTURE" write-tree)
    commit=$(git -C "$FIXTURE" -c user.name=test -c user.email=test@example.com commit-tree "$tree" -p dev -m 'change composer.lock')
    git -C "$FIXTURE" branch deps-base "$commit"

    run bash -c "cd '$FIXTURE' && ./bin/worktree-sail create feature/98-theta deps-base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"composer.lock differs from the main checkout's; installing Composer dependencies"* ]]
    [[ "$output" != *"composer install failed"* ]]
    serving "$FIXTURE/.claude/worktrees/98-theta"
}

@test "a warm create is serving requests in under 60 seconds" {
    local start elapsed
    start=$(date +%s)
    ( cd "$FIXTURE" && ./bin/worktree-sail create feature/91-beta >/dev/null 2>&1 )
    elapsed=$(( $(date +%s) - start ))
    serving "$FIXTURE/.claude/worktrees/91-beta"
    echo "warm create took ${elapsed}s" >&3
    [ "$elapsed" -lt 60 ]
}

@test "two creates started at the same moment both come up, on different ports" {
    ( cd "$FIXTURE" && ./bin/worktree-sail create feature/92-gamma >/dev/null 2>&1 ) & local p1=$!
    ( cd "$FIXTURE" && ./bin/worktree-sail create feature/93-delta >/dev/null 2>&1 ) & local p2=$!
    wait "$p1"; wait "$p2"
    local g="$FIXTURE/.claude/worktrees/92-gamma" d="$FIXTURE/.claude/worktrees/93-delta"
    serving "$g"
    serving "$d"
    [ "$(env_of "$g" APP_PORT)" != "$(env_of "$d" APP_PORT)" ]
}

@test "the worktree's PHP runs with opcache on and pcov off for the command line" {
    ( cd "$FIXTURE" && ./bin/worktree-sail create feature/90-alpha >/dev/null 2>&1 )
    run bash -c "cd '$FIXTURE/.claude/worktrees/90-alpha' && ./vendor/bin/sail php -r 'echo ini_get(\"opcache.enable_cli\"), \"/\", extension_loaded(\"pcov\") ? ini_get(\"pcov.enabled\") : \"0\";'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1/0"* ]]
}

@test "WORKTREE_POST_CREATE runs inside the new worktree" {
    printf 'WORKTREE_POST_CREATE="touch post-create-ran"\n' >> "$FIXTURE/.env"
    ( cd "$FIXTURE" && ./bin/worktree-sail create feature/94-epsilon >/dev/null 2>&1 )
    [ -f "$FIXTURE/.claude/worktrees/94-epsilon/post-create-ran" ]
}

@test "remove leaves nothing behind" {
    ( cd "$FIXTURE" && ./bin/worktree-sail create feature/95-zeta >/dev/null 2>&1 )
    local dir="$FIXTURE/.claude/worktrees/95-zeta" project db bucket
    project=$(env_of "$dir" COMPOSE_PROJECT_NAME); db=$(env_of "$dir" DB_DATABASE); bucket=$(env_of "$dir" AWS_BUCKET)

    run bash -c "cd '$FIXTURE' && ./bin/worktree-sail remove 95-zeta --branch"
    [ "$status" -eq 0 ]
    [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ]
    refute database_exists "$db"
    refute database_exists "${db}_testing"
    refute bucket_exists "$bucket"
    refute bucket_exists "${bucket}-public"
    [ ! -e "$dir" ]
    refute git -C "$FIXTURE" rev-parse --verify --quiet feature/95-zeta
}

@test "remove finishes a worktree git no longer lists, as gh pr merge --delete-branch leaves it" {
    ( cd "$FIXTURE" && ./bin/worktree-sail create feature/92-gamma >/dev/null 2>&1 )
    local dir="$FIXTURE/.claude/worktrees/92-gamma" project db
    project=$(env_of "$dir" COMPOSE_PROJECT_NAME); db=$(env_of "$dir" DB_DATABASE)
    rm "$dir/.git"
    git -C "$FIXTURE" worktree prune

    run bash -c "cd '$FIXTURE' && ./bin/worktree-sail remove 92-gamma --branch"
    [ "$status" -eq 0 ]
    [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ]
    refute database_exists "$db"
    [ ! -e "$dir" ]
    refute git -C "$FIXTURE" rev-parse --verify --quiet feature/92-gamma
}

@test "remove refuses a checkout git does not list that has a .git of its own" {
    mkdir -p "$FIXTURE/.claude/worktrees/rogue"
    git -C "$FIXTURE/.claude/worktrees/rogue" init --quiet
    run bash -c "cd '$FIXTURE' && ./bin/worktree-sail remove rogue"
    [ "$status" -ne 0 ]
    [ -d "$FIXTURE/.claude/worktrees/rogue/.git" ]
}

@test "git works inside a worktree's container" {
    ( cd "$FIXTURE" && ./bin/worktree-sail create feature/90-alpha >/dev/null 2>&1 )
    run bash -c "cd '$FIXTURE/.claude/worktrees/90-alpha' && ./vendor/bin/sail exec -T laravel.test git status --short"
    [ "$status" -eq 0 ]
}

@test "up --all starts every worktree, not only the first" {
    ( cd "$FIXTURE" && ./bin/worktree-sail create feature/92-gamma >/dev/null 2>&1 )
    ( cd "$FIXTURE" && ./bin/worktree-sail create feature/93-delta >/dev/null 2>&1 )
    ( cd "$FIXTURE" && ./bin/worktree-sail down --all >/dev/null 2>&1 )

    run bash -c "cd '$FIXTURE' && ./bin/worktree-sail up --all"
    [ "$status" -eq 0 ]
    serving "$FIXTURE/.claude/worktrees/92-gamma"
    serving "$FIXTURE/.claude/worktrees/93-delta"
}

@test "the test guard refuses a development database before RefreshDatabase can touch it" {
    ( cd "$FIXTURE" && ./bin/worktree-sail create feature/96-eta >/dev/null 2>&1 )
    local dir="$FIXTURE/.claude/worktrees/96-eta" app
    psql_q 'CREATE DATABASE "wts_canary"' >/dev/null
    docker exec "$(container_of pgsql)" psql -U sail -d wts_canary -qc 'CREATE TABLE precious (id int)'
    cat > "$dir/tests/Feature/CanaryTest.php" <<'PHP'
<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class CanaryTest extends TestCase
{
    use RefreshDatabase;

    public function test_it_runs(): void
    {
        $this->assertTrue(true);
    }
}
PHP
    app=$(docker ps -q --filter "label=com.docker.compose.project=$(env_of "$dir" COMPOSE_PROJECT_NAME)" \
        --filter label=com.docker.compose.service=laravel.test)

    run docker exec -u sail -e DB_DATABASE=wts_canary "$app" php artisan test tests/Feature/CanaryTest.php
    [ "$status" -ne 0 ]
    [[ "$output" == *"Refusing to run tests against the database [wts_canary]"* ]]
    # Untouched: not even RefreshDatabase's migrations ran against it.
    [ "$(docker exec "$(container_of pgsql)" psql -U sail -d wts_canary -tAc \
        "select string_agg(tablename, ',') from pg_tables where schemaname = 'public'")" = precious ]
}

@test "the test guard refuses a worktree's own development database even when its name ends in testing" {
    ( cd "$FIXTURE" && ./bin/worktree-sail create feature/97-load-testing >/dev/null 2>&1 )
    local dir="$FIXTURE/.claude/worktrees/97-load-testing" app db before
    db=$(env_of "$dir" DB_DATABASE)
    [[ "$db" == *testing ]]
    before=$(docker exec "$(container_of pgsql)" psql -U sail -d "$db" -tAc "select count(*) from pg_tables where schemaname = 'public'")
    cat > "$dir/tests/Feature/CanaryTest.php" <<'PHP'
<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class CanaryTest extends TestCase
{
    use RefreshDatabase;

    public function test_it_runs(): void
    {
        $this->assertTrue(true);
    }
}
PHP
    app=$(docker ps -q --filter "label=com.docker.compose.project=$(env_of "$dir" COMPOSE_PROJECT_NAME)" \
        --filter label=com.docker.compose.service=laravel.test)

    run docker exec -u sail -e DB_DATABASE="$db" "$app" php artisan test tests/Feature/CanaryTest.php
    [ "$status" -ne 0 ]
    [[ "$output" == *"Refusing to run tests against the database [$db]"* ]]
    [ "$(docker exec "$(container_of pgsql)" psql -U sail -d "$db" -tAc "select count(*) from pg_tables where schemaname = 'public'")" = "$before" ]
}

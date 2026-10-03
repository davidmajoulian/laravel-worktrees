# Shared helpers for the worktree-sail suite. Every test works against the
# fixture project setup_suite built; nothing here touches a real project.

AWS_CLI_IMAGE=${WORKTREE_AWS_CLI_IMAGE:-amazon/aws-cli:2.37.8}

# A worktree of the fixture, registered with git and holding a copy of the main
# .env -- the state `git worktree add` plus .worktreeinclude leaves behind,
# before worktree-sail has configured anything.
add_worktree() { # <folder> [branch]
    local dir="$FIXTURE/.claude/worktrees/$1" branch=${2:-test/$1}
    git -C "$FIXTURE" worktree add --quiet -b "$branch" "$dir" dev
    cp "$FIXTURE/.env" "$dir/.env"
    printf '%s' "$dir"
}

# Runs the worktree's own copy of the tool from inside it, the way a developer
# would.
wts() { # <dir> <args...>
    local dir=$1; shift
    ( cd "$dir" && ./bin/worktree-sail "$@" )
}

env_of() { # <dir> <key>
    grep "^$2=" "$1/.env" | tail -n 1 | cut -d= -f2- | tr -d "\"'"
}

container_of() { # <service>
    docker ps -q --filter "label=com.docker.compose.project=$FIXTURE_PROJECT" \
        --filter "label=com.docker.compose.service=$1" | head -n 1
}

psql_q() { # <sql>
    docker exec "$(container_of pgsql)" psql -U sail -d postgres -tAc "$1"
}

database_exists() { # <name>
    [ "$(psql_q "SELECT 1 FROM pg_database WHERE datname = '$1'")" = 1 ]
}

# The fixture's pinned Valkey image doubles as a small, already-pulled image for
# stand-in containers.
STANDIN_IMAGE=valkey/valkey:9.1.2-alpine

valkey() { # <args...>
    docker exec "$(container_of valkey)" valkey-cli "$@"
}

# The AWS CLI on the fixture's network, as the tool runs it.
s3() { # <args...>
    docker run --rm --network "${FIXTURE_PROJECT}_sail" \
        -e AWS_ACCESS_KEY_ID=sail -e AWS_SECRET_ACCESS_KEY=password \
        -e AWS_DEFAULT_REGION=us-east-1 -e AWS_ENDPOINT_URL=http://rustfs:9000 \
        "$AWS_CLI_IMAGE" "$@"
}

bucket_exists() { # <name>
    s3 s3api head-bucket --bucket "$1" >/dev/null 2>&1
}

http_status() { # <url>
    curl -s -o /dev/null -w '%{http_code}' "$1"
}

# Removes whatever a test left of a worktree without going through the tool
# under test, so a failing test cannot leave state that breaks the next one.
cleanup_worktree() { # <folder>
    local dir="$FIXTURE/.claude/worktrees/$1"
    # A test may have broken the worktree's role on purpose; restore it so the
    # cleanup itself can drop its databases.
    [ ! -f "$dir/.env" ] || sed -i.bak 's/^DB_USERNAME=.*/DB_USERNAME=sail/' "$dir/.env" && rm -f "$dir/.env.bak"
    ( cd "$FIXTURE" && ./bin/worktree-sail remove "$1" --branch ) >/dev/null 2>&1 || true
    git -C "$FIXTURE" worktree remove --force "$dir" >/dev/null 2>&1 || true
    rm -rf "$dir"
}

# `! cmd` never fails a bats test (errexit ignores a negated command), so
# negative checks go through this instead.
refute() { # <command...>
    if "$@"; then return 1; fi
}

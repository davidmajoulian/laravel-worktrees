#!/usr/bin/env bats
# Branch names with slashes, and the names commands accept.

load helpers

teardown() {
    cleanup_worktree 12-login
}

@test "commands accept a worktree's branch name as well as its folder name" {
    local dir db
    dir=$(add_worktree 12-login feature/12-login)
    wts "$dir" prepare >/dev/null
    db=$(env_of "$dir" DB_DATABASE)
    database_exists "$db"

    run bash -c "cd '$FIXTURE' && ./bin/worktree-sail destroy feature/12-login"
    [ "$status" -eq 0 ]
    refute database_exists "$db"
}

@test "remove refuses a name that is a path" {
    run bash -c "cd '$FIXTURE' && ./bin/worktree-sail remove feature/12-login"
    [ "$status" -ne 0 ]
    [[ "$output" == *usage* ]]
}

@test "remove --branch deletes no branch when there was no worktree folder" {
    git -C "$FIXTURE" branch feature/77-ghost dev
    run bash -c "cd '$FIXTURE' && ./bin/worktree-sail remove 77-ghost --branch"
    git -C "$FIXTURE" rev-parse --verify --quiet feature/77-ghost >/dev/null
    git -C "$FIXTURE" branch -D feature/77-ghost >/dev/null
}

@test "remove --branch never deletes a protected base branch, even one checked out nowhere" {
    # "main" is not checked out in the fixture, so git itself would not refuse.
    git -C "$FIXTURE" branch main dev
    mkdir -p "$FIXTURE/.claude/worktrees/main"
    run bash -c "cd '$FIXTURE' && ./bin/worktree-sail remove main --branch"
    [ "$status" -eq 0 ]
    git -C "$FIXTURE" rev-parse --verify --quiet main >/dev/null
    [ ! -e "$FIXTURE/.claude/worktrees/main" ]
    git -C "$FIXTURE" branch -D main >/dev/null
}

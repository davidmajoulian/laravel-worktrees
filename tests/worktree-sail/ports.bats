#!/usr/bin/env bats
# Port allocation: worktrees set up at the same moment, or sitting in folders a
# glob would miss, must never be handed the same port.

load helpers

teardown() {
    local w
    for w in p1 p2 p3 p4 p5 other-nested; do cleanup_worktree "$w"; done
    git -C "$FIXTURE" worktree remove --force "$FIXTURE/.claude/worktrees/deep/nested" >/dev/null 2>&1 || true
    rm -rf "$FIXTURE/.claude/worktrees/deep"
}

@test "worktrees configured at the same moment get distinct ports" {
    local w dirs=() pids=()
    for w in p1 p2 p3 p4 p5; do dirs+=("$(add_worktree "$w")"); done

    for w in "${dirs[@]}"; do wts "$w" init >/dev/null 2>&1 & pids+=($!); done
    for w in "${pids[@]}"; do wait "$w"; done

    local apps vites
    apps=$(for w in "${dirs[@]}"; do env_of "$w" APP_PORT; done)
    vites=$(for w in "${dirs[@]}"; do env_of "$w" VITE_PORT; done)
    [ "$(printf '%s\n' "$apps" | sort -u | wc -l)" -eq 5 ]
    [ "$(printf '%s\n' "$vites" | sort -u | wc -l)" -eq 5 ]
    # None of them took the main checkout's ports.
    refute grep -qx 18080 <<< "$apps"
}

@test "a worktree in a nested folder still holds on to its port" {
    local nested other
    nested="$FIXTURE/.claude/worktrees/deep/nested"
    git -C "$FIXTURE" worktree add --quiet -b test/nested-deep "$nested" dev
    cp "$FIXTURE/.env" "$nested/.env"
    wts "$nested" init >/dev/null

    other=$(add_worktree other-nested)
    wts "$other" init >/dev/null

    [ "$(env_of "$nested" APP_PORT)" != "$(env_of "$other" APP_PORT)" ]
}

@test "a stale lock left by a process that died does not block allocation" {
    local dir
    dir=$(add_worktree p1)
    local dead
    sh -c 'exit 0' & dead=$!; wait "$dead"
    mkdir "$FIXTURE/.git/worktree-sail.lock"
    echo "$dead" > "$FIXTURE/.git/worktree-sail.lock/pid"

    run wts "$dir" init
    [ "$status" -eq 0 ]
    [ -n "$(env_of "$dir" APP_PORT)" ]
    [ ! -e "$FIXTURE/.git/worktree-sail.lock" ]
}

@test "a run started while the lock is held by its own parent does not wait for itself" {
    local dir
    dir=$(add_worktree p2)
    mkdir "$FIXTURE/.git/worktree-sail.lock"
    echo $$ > "$FIXTURE/.git/worktree-sail.lock/pid"

    run bash -c "cd '$dir' && WORKTREE_SAIL_LOCK_PID=$$ ./bin/worktree-sail init"
    rm -rf "$FIXTURE/.git/worktree-sail.lock"
    [ "$status" -eq 0 ]
    [ -n "$(env_of "$dir" APP_PORT)" ]
}

@test "a lock left without a pid by a run that died is cleared after a minute" {
    local dir
    dir=$(add_worktree p3)
    mkdir "$FIXTURE/.git/worktree-sail.lock"
    touch -t "$(date -v-2M +%Y%m%d%H%M.%S 2>/dev/null || date -d '2 minutes ago' +%Y%m%d%H%M.%S)" "$FIXTURE/.git/worktree-sail.lock"

    run wts "$dir" init
    [ "$status" -eq 0 ]
    [ ! -e "$FIXTURE/.git/worktree-sail.lock" ]
    cleanup_worktree p3
}

@test "settings that must be numbers are refused when they are not" {
    local dir
    dir=$(add_worktree p4)
    printf 'WORKTREE_LOCK_TIMEOUT=soon\n' >> "$FIXTURE/.env"
    run wts "$dir" init
    sed -i.bak '/^WORKTREE_LOCK_TIMEOUT=soon$/d' "$FIXTURE/.env" && rm -f "$FIXTURE/.env.bak"
    [ "$status" -ne 0 ]
    [[ "$output" == *"WORKTREE_LOCK_TIMEOUT must be a number"* ]]
    cleanup_worktree p4
}

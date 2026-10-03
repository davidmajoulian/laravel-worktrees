#!/usr/bin/env bats
# Resource ceilings on a worktree's application container, and the settings it
# shares with the main checkout. Checked on the rendered Compose configuration,
# so no container has to start.

load helpers

setup() {
    DIR=$(add_worktree caps)
    wts "$DIR" init >/dev/null
}

teardown() {
    cleanup_worktree caps
}

rendered() { # [VAR=value...]
    ( cd "$DIR" && env "$@" docker compose -f compose.worktree.yaml config 2>/dev/null )
}

@test "a worktree container has a memory ceiling by default and none on swap beyond it" {
    run rendered
    [ "$status" -eq 0 ]
    [[ "$output" == *"mem_limit: \"5368709120\""* ]]
    [[ "$output" == *"memswap_limit: \"5368709120\""* ]]
}

@test "the memory ceiling follows SAIL_CONTAINER_MEM_LIMIT" {
    run rendered SAIL_CONTAINER_MEM_LIMIT=2g
    [[ "$output" == *"mem_limit: \"2147483648\""* ]]
}

@test "a CPU ceiling applies only when SAIL_CONTAINER_CPUS is set" {
    run rendered
    [ "$status" -eq 0 ]
    [[ "$output" == *"mem_limit"* ]]
    refute grep -Eq 'cpus: "?([1-9]|0\.[0-9]*[1-9])' <<< "$output"
    run rendered SAIL_CONTAINER_CPUS=2
    [[ "$output" == *"cpus: 2"* ]]
}

@test "git trusts the bind-mounted checkout and PHP reads the shared ini folder" {
    run rendered
    [[ "$output" == *"GIT_CONFIG_KEY_0: safe.directory"* ]]
    [[ "$output" == *"GIT_CONFIG_VALUE_0: /var/www/html"* ]]
    [[ "$output" == *"PHP_INI_SCAN_DIR: :/etc/sail/php"* ]]
}

@test "init records the main checkout's git directory for tools that read history" {
    [ "$(env_of "$DIR" SAIL_GIT_COMMON_DIR)" = "$FIXTURE/.git" ]
}

@test "the main checkout's git directory is mounted read-only at its own path" {
    run rendered
    [[ "$output" == *"target: $FIXTURE/.git"* ]]
    [[ "$output" == *"read_only: true"* ]]
}

@test "the app and Vite ports listen on this machine only unless SAIL_BIND_ADDRESS says otherwise" {
    run rendered
    [ "$status" -eq 0 ]
    [ "$(grep -c 'host_ip: 127.0.0.1' <<< "$output")" -eq 2 ]
    run rendered SAIL_BIND_ADDRESS=0.0.0.0
    [ "$(grep -c 'host_ip: 0.0.0.0' <<< "$output")" -eq 2 ]
}

@test "the main checkout's app and Vite ports listen on this machine only too" {
    run bash -c "cd '$FIXTURE' && docker compose config 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(grep -c 'host_ip: 127.0.0.1' <<< "$output")" -ge 2 ]
}

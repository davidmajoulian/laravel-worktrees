#!/usr/bin/env bats
# Object storage: every bucket a checkout names is created for it, public ones
# can be read anonymously, and a worktree's buckets go when it does.

load helpers

setup() {
    DIR=$(add_worktree bkt)
}

teardown() {
    cleanup_worktree bkt
    cleanup_worktree a-very-long-branch-name-that-keeps-going-and-going-past-the-s3-limit
}

@test "prepare names and creates a private and a public bucket for the worktree" {
    run wts "$DIR" prepare
    [ "$status" -eq 0 ]
    [ "$(env_of "$DIR" AWS_BUCKET)" = bkt ]
    [ "$(env_of "$DIR" AWS_PUBLIC_BUCKET)" = bkt-public ]
    bucket_exists bkt
    bucket_exists bkt-public
}

@test "objects in the public bucket are readable anonymously and private ones are not" {
    wts "$DIR" prepare >/dev/null
    printf 'hello' > "$BATS_TEST_TMPDIR/hello.txt"
    docker run --rm --network "${FIXTURE_PROJECT}_sail" -v "$BATS_TEST_TMPDIR:/data:ro" \
        -e AWS_ACCESS_KEY_ID=sail -e AWS_SECRET_ACCESS_KEY=password -e AWS_DEFAULT_REGION=us-east-1 \
        -e AWS_ENDPOINT_URL=http://rustfs:9000 --entrypoint sh "$AWS_CLI_IMAGE" -c \
        'aws s3 cp /data/hello.txt s3://bkt/hello.txt >/dev/null && aws s3 cp /data/hello.txt s3://bkt-public/hello.txt >/dev/null'

    [ "$(http_status http://localhost:19000/bkt-public/hello.txt)" = 200 ]
    [ "$(http_status http://localhost:19000/bkt/hello.txt)" = 403 ]
}

@test "prepare is idempotent" {
    wts "$DIR" prepare >/dev/null
    run wts "$DIR" prepare
    [ "$status" -eq 0 ]
    bucket_exists bkt-public
}

@test "prepare in the main checkout creates the main checkout's buckets" {
    run bash -c "cd '$FIXTURE' && ./bin/worktree-sail prepare"
    [ "$status" -eq 0 ]
    bucket_exists local-private
    bucket_exists local-public
    [ "$(env_of "$FIXTURE" AWS_BUCKET)" = local-private ]
}

@test "destroy removes the worktree's buckets with everything in them, never the main checkout's" {
    ( cd "$FIXTURE" && ./bin/worktree-sail prepare >/dev/null )
    wts "$DIR" prepare >/dev/null
    s3 s3api put-object --bucket bkt --key x --body /etc/hostname >/dev/null

    run wts "$DIR" destroy
    [ "$status" -eq 0 ]
    refute bucket_exists bkt
    refute bucket_exists bkt-public
    bucket_exists local-private
    bucket_exists local-public
}

@test "bucket names stay valid for long branch names" {
    local d name
    d=$(add_worktree a-very-long-branch-name-that-keeps-going-and-going-past-the-s3-limit)
    wts "$d" init >/dev/null
    for name in "$(env_of "$d" AWS_BUCKET)" "$(env_of "$d" AWS_PUBLIC_BUCKET)"; do
        [ "${#name}" -le 63 ]
        [[ "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]
    done
    [[ "$(env_of "$d" AWS_PUBLIC_BUCKET)" == *-public ]]
}

@test "bucket work always goes to the shared S3 service, whatever AWS_ENDPOINT says" {
    printf 'AWS_ENDPOINT=http://localhost:9\n' >> "$DIR/.env"
    run wts "$DIR" prepare
    [ "$status" -eq 0 ]
    bucket_exists bkt
}

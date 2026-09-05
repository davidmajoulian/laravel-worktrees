#!/usr/bin/env sh
#
# Project-local Sail entry point.
#
# The conventional Sail alias
#
#     alias sail='sh $([ -f sail ] && echo sail || echo vendor/bin/sail)'
#
# prefers a ./sail file over vendor/bin/sail, so every `sail ...` run from this
# repository passes through here. (It is executed with `sh`, so this file has to
# stay POSIX shell -- no bashisms.)
#
# In the main checkout this forwards to vendor/bin/sail and does nothing else.
#
# In a git worktree it first makes sure the worktree has been given its own
# ports, Compose project and database. That step matters: a fresh worktree holds
# a verbatim copy of the main checkout's .env -- same COMPOSE_PROJECT_NAME, no
# SAIL_FILES -- so `sail up -d` would otherwise reconcile the *main* checkout's
# Compose project and recreate its application container bind-mounted onto this
# worktree's files.

set -e

root=$(git rev-parse --show-toplevel 2>/dev/null) || root=''

if [ -n "$root" ]; then
    # The main checkout is the parent of the shared git directory; in a linked
    # worktree --git-common-dir points back at it.
    main_root=$(cd "$root" && cd "$(dirname "$(git rev-parse --git-common-dir)")" && pwd -P)

    if [ "$root" != "$main_root" ] && [ -x "$root/bin/worktree-sail" ]; then
        if ! grep -q '^SAIL_FILES=compose.worktree.yaml$' "$root/.env" 2>/dev/null; then
            echo "==> this worktree is not configured for Sail yet; configuring it first" >&2
            "$root/bin/worktree-sail" prepare
            echo "==> configured; handing over to Sail" >&2
        fi
    fi
fi

exec sh "${root:-.}/vendor/bin/sail" "$@"

# Failure modes worth recognising

| Symptom | What it means | Fix |
| --- | --- | --- |
| `shared network '<project>_sail' is missing` | the main checkout is down; worktrees depend on its services | `sail up -d` in the main checkout |
| Worktree page returns 500 | its database has no schema yet | `bin/worktree-sail up` (which migrates), or `sail artisan migrate` |
| `port is already allocated` on `sail up -d` | the band overlaps another project | pick another band and update `.env` |
| `Refusing to run tests against the database [...]` | `.env.testing` is missing, so the suite was about to run against development data | `bin/worktree-sail testing-env` |
| `this worktree is not configured for Sail yet` | informational — the shim is configuring it and will hand over to Sail | nothing |
| `service "laravel.test" depends on undefined service "pgsql"` | `depends_on` survived into the worktree compose file | it needs `depends_on: !reset null`; requires Compose 2.24+ |
| Every checkout calls itself "html" | something used `base_path()` inside the container | use `IGNITION_LOCAL_SITES_PATH`, which Sail sets to the host directory |
| Pulls hang on `error getting credentials` | Docker Desktop's credential helper is stuck; not a project problem | restart Docker Desktop, or drop `"credsStore"` from `~/.docker/config.json` |
| Tests behave as though a recent `.env` edit never happened | `.env.testing` is a snapshot taken when it was generated | `bin/worktree-sail testing-env` |
| A worktree Claude Code removed left containers behind | Claude Code deletes the directory and knows nothing about Docker | `bin/worktree-sail teardown <path>` — it works from the directory name alone |

## Shutting the stack down

Order matters, and getting it wrong fails quietly. Worktree containers are attached
to the **main** checkout's network, so `sail down` in the main checkout cannot
remove that network:

```
Network <project>_sail  Removing
Network <project>_sail  Resource is still in use
```

Compose still removes main's own containers and **still exits 0** — the warning is
one line in the middle of a lot of output. What you are left with is an orphaned
network and a worktree container that is still running against a database, cache
and mail server that no longer exist, so it starts returning 500s that look like an
application bug.

Take worktrees down first, then the main checkout:

```bash
cd .claude/worktrees/<name> && ./bin/worktree-sail down
cd <main checkout>         && sail down
```

`sail down` without `-v` keeps the volumes, so every database survives. `-v`
destroys them.

To recover from having done it in the wrong order: take the worktree down,
`docker network rm <project>_sail`, then bring both back up. Nothing is lost.

## Things this setup deliberately does not do

- **Delete search indexes, object-storage buckets or RabbitMQ queues on teardown.**
  Each worktree gets its own prefix, bucket name or queue name so they never
  collide, but removing them is manual. Databases and Redis/Valkey keys *are*
  reclaimed.
- **Fire on Claude Code's `WorktreeRemove` hook.** That hook does not run for
  worktrees created with git — only for ones a `WorktreeCreate` hook made, and
  `WorktreeCreate` replaces git worktree creation entirely, taking
  `.worktreeinclude` processing with it. Verified on Claude Code 2.1.226.
- **Touch the compose file Sail generates.** Everything is layered on top through
  `SAIL_FILES` and `.env`, so `sail:install` can regenerate it at any time.

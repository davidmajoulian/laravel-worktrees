# Isolated Sail environments per git worktree

Every checkout of this repository — the main one and each worktree — runs its
own Laravel application container, on its own port, against its own database.
They all share a single Postgres, Redis and Mailpit.

That combination is the point. Full isolation would mean four containers per
branch and a fresh database server each time; full sharing would mean two
branches trampling each other's data. This splits the difference along the line
that matters: **processes are shared, state is not.**

```
                     main checkout                    .claude/worktrees/feature-x
                     compose.yaml                     compose.worktree.yaml
                     ┌──────────────────┐             ┌──────────────────┐
                     │ laravel.test :80 │             │ laravel.test:8001│
                     └────────┬─────────┘             └────────┬─────────┘
                              │                                │
                              └──────────┬─────────────────────┘
                                         │  network: learn-worktrees_sail
                        ┌────────────────┼────────────────┐
                        │                │                │
                   ┌────┴────┐      ┌────┴────┐      ┌────┴────┐
                   │  pgsql  │      │  redis  │      │ mailpit │
                   └─────────┘      └─────────┘      └─────────┘
                   laravel                keys prefixed        one shared
                   laravel_feature_x      per checkout         inbox
```

`compose.yaml` is exactly what `sail:install` generated and is never edited.
Everything here is layered on top of it.

## Quick reference

Run these from anywhere inside the checkout you mean.

| Command | What it does |
| --- | --- |
| `bin/worktree-sail create <branch> [base]` | worktree + dependencies + config + database + container + migrations |
| `bin/worktree-sail up` | configure and start the current worktree (idempotent) |
| `bin/worktree-sail prepare` | config + shared services + database, but no container |
| `bin/worktree-sail init` | rewrite `.env` only; touches no containers |
| `bin/worktree-sail status` | every checkout, its port, state and database |
| `bin/worktree-sail down` | stop and remove this worktree's container |
| `bin/worktree-sail destroy` | …plus its networks, volumes, database and cache keys |
| `bin/worktree-sail remove <name> [--branch]` | destroy everything, then drop the worktree |

The main checkout is ordinary Sail: `sail up -d`, `sail down`. The script
refuses to act on it.

## Creating a worktree

**With Claude Code.** Tick the worktree box (or ask Claude to make one). It runs
`git worktree add` into `.claude/worktrees/<name>` and copies whatever
`.worktreeinclude` matches. The tooling itself is tracked, so it arrives with
the checkout. Then run `bin/worktree-sail up` — or just run `sail up -d`, which
configures the worktree first (see [The `./sail` shim](#the-sail-shim)).

**From the shell.** `bin/worktree-sail create my-feature` does the whole thing in
one step, about seven seconds.

## How it works

### 1. `SAIL_FILES` swaps the Compose file

Sail reads `SAIL_FILES` from `.env` and turns it into `-f` arguments:

```bash
# vendor/laravel/sail/bin/sail
export SAIL_FILES=${SAIL_FILES:-""}
...
for FILE in "${SAIL_FILES[@]}"; do COMPOSE_CMD+=(-f "$FILE"); done
```

Because an explicit `-f` is passed, Compose does **not** also load `compose.yaml`.
So a worktree's project contains only what `compose.worktree.yaml` declares —
Postgres, Redis and Mailpit are not in it and cannot be started a second time.
No override file could achieve that; overrides can add services, not remove them.

### 2. `extends` inherits the app service instead of copying it

```yaml
services:
    laravel.test:
        extends:
            file: compose.yaml
            service: laravel.test
        depends_on: !reset null
        networks: [sail]
```

The service definition is inherited, so PHP version, bind mounts, port variables
and Xdebug wiring stay in step with whatever `sail:install` writes. `extends`
*does* copy `depends_on`, which would then point at services this project does
not define, so `!reset null` clears it.

The inherited `image:` is `sail-8.5/app` — the same name the main checkout
builds. A worktree therefore starts from an image that already exists rather
than building its own.

### 3. An external network reaches the shared services

```yaml
networks:
    sail:
        external: true
        name: '${SAIL_SHARED_NETWORK:-learn-worktrees_sail}'
```

Joining the main project's network is what makes the hostnames `pgsql`, `redis`
and `mailpit` resolve inside a worktree's container. `external: true` also means
Compose will never delete it during a worktree teardown.

The main checkout's project name is pinned in its `.env`
(`COMPOSE_PROJECT_NAME=learn-worktrees`) so the network name is predictable.

### 4. `.env` carries everything else

`bin/worktree-sail init` writes these into the worktree's `.env`:

| Variable | Purpose | Example |
| --- | --- | --- |
| `SAIL_FILES` | selects the worktree Compose file | `compose.worktree.yaml` |
| `SAIL_SHARED_NETWORK` | which network to join | `learn-worktrees_sail` |
| `COMPOSE_PROJECT_NAME` | separates the Compose project | `learn-worktrees-feature-x` |
| `APP_PORT` / `VITE_PORT` | separates the published ports | `8001` / `5174` |
| `APP_URL` | matches the port | `http://localhost:8001` |
| `DB_DATABASE` | own database on the shared server | `laravel_feature_x` |
| `REDIS_PREFIX` / `CACHE_PREFIX` | own key namespace on the shared Redis | `feature_x_database_` |

Docker Compose reads `COMPOSE_PROJECT_NAME` from `.env` itself, and
`laravel-vite-plugin` already honours `VITE_PORT`, so no config file needs to
change.

Ports are allocated from 8001 (app) and 5174 (Vite) upwards, skipping anything a
host process is listening on and anything any container has published, running or
not. `up` re-checks at start time and moves the port if it has been taken since.

## Tracked versus generated

This distinction is what keeps branches clean:

| | |
| --- | --- |
| **Tracked** — reviewable, inherited by every worktree | `compose.worktree.yaml`, `bin/worktree-sail`, `sail`, `.worktreeinclude` |
| **Generated** — git-ignored, never in a commit | `.claude/worktrees/`, and each worktree's rewritten `.env` |

Keeping the tooling tracked means `git worktree add` alone supplies it: nothing
to copy, and no chance of copies drifting from the main checkout.

## `.worktreeinclude`

`git worktree add` materialises tracked files only, so a new worktree has no
`.env` and no dependencies — and since the container bind-mounts the worktree at
`/var/www/html`, it would boot into a directory with no `vendor/autoload.php`.

Claude Code reads `.worktreeinclude` when it creates a worktree, matching its
`.gitignore`-style patterns against

```bash
git ls-files --others --ignored --exclude-standard --directory
```

and copying what matches. `bin/worktree-sail create` runs the same query, so both
routes produce identical results. On APFS the copy uses `cp -c`, which clones:
`vendor/` and `node_modules/` together take about two seconds and no extra disk.

## The `./sail` shim

The usual alias prefers a project-local `sail` file:

```bash
alias sail='sh $([ -f sail ] && echo sail || echo vendor/bin/sail)'
```

so `./sail` is the one place every `sail` command passes through. In the main
checkout it just forwards to `vendor/bin/sail`. In a worktree it first checks
whether the worktree has been configured, and runs `worktree-sail prepare` if not.

That check is not cosmetic. A brand-new worktree holds a verbatim copy of the
main checkout's `.env` — same `COMPOSE_PROJECT_NAME`, no `SAIL_FILES` — so
`sail up -d` would reconcile the **main** project from the worktree's directory
and recreate the main application container bind-mounted onto the worktree's
files. The shim closes that window.

`sail up -d` in a worktree starts the container but does not migrate. Use
`bin/worktree-sail up` for the full sequence.

## Tearing down

`remove` deletes everything a worktree created and nothing else:

- containers, networks and volumes carrying its Compose project label
- its database on the shared Postgres
- its Redis and cache keys, by prefix
- the worktree directory, and its branch with `--branch`

The shared services, their volumes and the shared network are all selected by the
*main* project's labels, so they are never in scope. Two guards make that
explicit: `resolve_project()` never resolves a worktree to the main project, and
the database drop refuses to touch the main checkout's database.

## Verifying it

`/status` on each checkout shows what is shared and what is not:

```
http://localhost/status          main checkout
http://localhost:8001/status     a worktree
http://localhost:8025            Mailpit, shared by all of them
```

The Postgres address, Redis run id and Mailpit address are identical across
checkouts. The container, Compose project, port, database, row counts and key
prefixes differ.

## Changing the stack later

Everything flows from `compose.yaml`, so treat it as the single source of truth:

- **Adding a service** (`sail:install --with=...`): it lands in `compose.yaml`,
  which means the main checkout runs it and every worktree shares it. If
  worktrees need their own logical slice, give it a per-worktree prefix or
  database in `bin/worktree-sail`'s `cmd_init`, next to `DB_DATABASE`.
- **Changing PHP version**: `compose.worktree.yaml` inherits `build` and `image`
  through `extends`, so worktrees follow automatically. Rebuild once in the main
  checkout (`sail build --no-cache`); worktrees reuse the image.
- **A worktree that needs its own copy of a service**: add it to
  `compose.worktree.yaml` as a normal service. It will be namespaced by the
  worktree's Compose project, so it cannot collide.

## Troubleshooting

**`shared network 'learn-worktrees_sail' is missing`** — the main checkout is
down. Run `sail up -d` there first; the worktrees depend on its services.

**A worktree's page returns 500** — its database has no schema yet. Run
`bin/worktree-sail up`, which migrates, or `sail artisan migrate`.

**`this worktree is not configured for Sail yet`** — informational; the shim is
configuring it and will hand over to Sail straight afterwards.

**Port already in use** — allocation skips busy ports automatically. To pin one,
set `APP_PORT` in that worktree's `.env` by hand; `init` keeps any value that
differs from the main checkout's.

**Image pulls hang with `error getting credentials`** — a Docker Desktop problem,
not a repository one: `docker-credential-desktop` stalls and blocks the pull.
Restart Docker Desktop, or remove `"credsStore": "desktop"` from
`~/.docker/config.json` if `auths` is empty anyway.

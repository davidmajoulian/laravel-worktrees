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
                                         │  network: laravel-worktrees_sail
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

This document is the reference. To learn how it is put together — in build order,
with the reasoning and the dead ends — read
[building-it-from-scratch.md](building-it-from-scratch.md).

## Quick reference

Run these from anywhere in the repository. Where a command takes `[name|--all]`,
no argument means the worktree you are standing in; running it from the main
checkout without one is an error rather than a guess, so nothing acts on a
worktree you did not name.

| Command | What it does |
| --- | --- |
| `bin/worktree-sail create <branch> [base]` | worktree + dependencies + config + databases + buckets + container + migrations, then `WORKTREE_POST_CREATE` |
| `bin/worktree-sail up [name\|--all]` | configure and start a worktree (idempotent) |
| `bin/worktree-sail prepare` | config + shared services + both databases + buckets, but no container. In the main checkout: shared services, its databases and its buckets |
| `bin/worktree-sail init` | rewrite `.env` only; touches no containers |
| `bin/worktree-sail testing-env` | (re)write `.env.testing`; works in the main checkout too |
| `bin/worktree-sail status` | every checkout, its port, state and database |
| `bin/worktree-sail down [name\|--all]` | stop and remove a worktree's container |
| `bin/worktree-sail destroy [name\|--all]` | …plus its networks, volumes, databases, keys and buckets |
| `bin/worktree-sail remove <name> [--branch]` | destroy everything, then drop the worktree |
| `bin/worktree-sail teardown <path>` | Docker, database and bucket cleanup only, no git |

A name is the worktree's folder under `.claude/worktrees/`. `create` names the
folder after the branch's last segment (`feature/12-login` → `12-login`), so the
branch name works wherever a name does — except `remove`, which takes the folder
name only and refuses anything with a slash in it.

The main checkout is ordinary Sail: `sail up -d`, `sail down`. Apart from
`prepare` and `testing-env`, the script refuses to act on it.

## Creating a worktree

**With Claude Code.** Tick the worktree box (or ask Claude to make one). It runs
`git worktree add` into `.claude/worktrees/<name>` and copies whatever
`.worktreeinclude` matches. The tooling itself is tracked, so it arrives with
the checkout. Then run `bin/worktree-sail up` — or just run `sail up -d`, which
configures the worktree first (see [The `./sail` shim](#the-sail-shim)).

**From the shell.** `bin/worktree-sail create feature/12-login` does the whole
thing in one step. With no `[base]` it branches from the remote's default branch
— `WORKTREE_BASE_BRANCH` in the main `.env` overrides that — fetched first; when
the fetch fails it says so and starts from the copy fetched last. The branch has no upstream, so a
bare `git push` can never land on the base branch; push with `-u origin HEAD`.

`WORKTREE_POST_CREATE`, if the main `.env` sets it, runs inside the new worktree
once it is up — for a project-specific step such as
`./vendor/bin/sail npx playwright install chromium`.

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
        name: '${SAIL_SHARED_NETWORK:-laravel-worktrees_sail}'
```

Joining the main project's network is what makes the hostnames `pgsql`, `redis`
and `mailpit` resolve inside a worktree's container. `external: true` also means
Compose will never delete it during a worktree teardown.

The main checkout's project name is pinned in its `.env`
(`COMPOSE_PROJECT_NAME=laravel-worktrees`) so the network name is predictable.

### 4. `.env` carries everything else

`bin/worktree-sail init` writes these into the worktree's `.env`:

| Variable | Purpose | Example |
| --- | --- | --- |
| `SAIL_FILES` | selects the worktree Compose file | `compose.worktree.yaml` |
| `SAIL_SHARED_NETWORK` | which network to join | `laravel-worktrees_sail` |
| `COMPOSE_PROJECT_NAME` | separates the Compose project; `-wt-` keeps it clear of other projects' names | `laravel-worktrees-wt-feature-x` |
| `APP_PORT` / `VITE_PORT` | separates the published ports | `8001` / `5174` |
| `APP_URL` | matches the port | `http://localhost:8001` |
| `DB_DATABASE` | own database on the shared server | `laravel_feature_x` |
| `DB_DATABASE` in `.env.testing` | own **test** database | `laravel_feature_x_testing` |
| `REDIS_PREFIX` / `CACHE_PREFIX` | own key namespace on the shared Redis/Valkey. `:` cannot occur in a folder slug, so no worktree's prefix is the start of another's | `wt:feature-x:db:` / `wt:feature-x:cache:` |
| `REDIS_CACHE_DB` | own cache **database** on the shared Redis/Valkey: Laravel's `cache:clear` runs `FLUSHDB`, which ignores prefixes, so a shared one would clear every checkout's cache and restart every queue worker. Allocated under the lock, like the ports, from the lowest number no other checkout uses (`WORKTREE_REDIS_DATABASES`, default 16, is the server's count) | `2` |
| `SAIL_GIT_COMMON_DIR` | the main checkout's `.git`, mounted read-only at the same path so git works in the container | `/path/to/app/.git` |
| bucket variables | own buckets on the shared S3 (see below) | `feature-x`, `feature-x-public` |

Values that need it — a path with a space, say — are written single-quoted, which
Laravel's dotenv, Compose and Sail's `source ./.env` all read literally. Names are
cut to fit (Postgres's 63 characters, S3's 63) with a short hash of the full name
kept on the end, so two long branch names never meet; and `init` refuses a folder
whose names another checkout already holds (`v1.2` and `v1-2` reduce to the same
ones) rather than let them share state.

`init` marks the `.env` with the folder it belongs to (`WORKTREE_SAIL_ROOT`). A
`.env` without that mark for *this* folder — copied from the main checkout or from
a sibling — is replaced with this worktree's own, ports included, and teardown
never acts on what such a file says. The `./sail` shim checks the same mark.

A worktree set up by an earlier version (no mark, named `<main>-<folder>`) is
adopted on its next `init` under the names it already has, so its database and
keys stay where they are. Re-running `init` never renames an existing worktree.

`down`, `destroy` and `remove` do not ask Compose to take the stack down —
`down --remove-orphans` removes every container of the project *name*, including
another project's that shares it. Containers are removed one by one, and only
those Compose ran from this worktree's folder. Networks and volumes record no
folder, so they are only removed under the worktree's own `-wt-` project name,
which no other project uses — never under an older version's name, where a
stopped project elsewhere could own them. Containers get ten seconds to stop
cleanly before they are removed.

The app and Vite ports listen on `127.0.0.1` (`SAIL_BIND_ADDRESS` opens them), set
through `ports: !override`, which needs Docker Compose 2.24.4 or newer. A project
whose own `compose.override.yaml` adds more `laravel.test` ports must list them in
that `!override` too, since it replaces the list.

Two limits: a repository path containing a single quote cannot be written to
`.env` (`init` stops with an error), and git's `worktree.useRelativePaths` setting
writes a relative path into a worktree's `.git`, which the same-path mount of the
main `.git` does not resolve inside the container.

Docker Compose reads `COMPOSE_PROJECT_NAME` from `.env` itself, and
`laravel-vite-plugin` already honours `VITE_PORT`, so no config file needs to
change.

Ports are allocated from 8001 (app) and 5174 (Vite) upwards, skipping anything a
host process is listening on and anything a running container has published. `up`
re-checks at start time and moves the port if it has been taken since.

That detection has a limit worth knowing: a **stopped** container reports no
ports, so it cannot see a project that is currently down. Within one project that
is fine — its worktrees are visible to each other through `.env`. Across projects
it is not, which is what the next section is about.

## Tracked versus generated

This distinction is what keeps branches clean:

| | |
| --- | --- |
| **Tracked** — reviewable, inherited by every worktree | `compose.worktree.yaml`, `compose.override.yaml`, `bin/worktree-sail`, `sail`, `.worktreeinclude` |
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

The shim is a **passthrough**: after the check it hands every argument to Sail
untouched, so it does not expose any of `worktree-sail`'s commands. `sail create
my-feature` reaches `docker compose create`, which is a real command meaning
something else, and `sail status` reaches a command that does not exist at all.
That separation is deliberate — shadowing Sail's own verbs would mean you could no
longer read `sail down` in a script and know what it does. If the typing bothers
you, the README has a `wt` shell function.

## Tearing down

`remove` deletes everything a worktree created and nothing else:

- containers (with their anonymous volumes), networks and volumes carrying its
  Compose project label
- its databases on the shared server: development, test, the `<test>_test_<n>`
  ones Laravel's parallel testing makes, and any named by
  `WORKTREE_EXTRA_DATABASE_SUFFIXES`
- its Redis/Valkey keys, by prefix, in **every** logical database — Laravel's
  cache connection uses database 1, which a plain scan of database 0 never sees
- its buckets, with everything in them
- the worktree directory, and its branch with `--branch`

A stopped shared service is started for the teardown rather than skipped, and
anything that still cannot be removed is listed and makes the command fail:
`remove` then **keeps the folder**, because its `.env` is the way back to what is
left. A worktree git no longer lists — what `gh pr merge --delete-branch` leaves
behind — is finished off rather than refused; a folder git does not list but
that has a `.git` of its own is refused, since it is somebody's checkout.

The shared services, their volumes and the shared network are all selected by the
*main* project's labels, so they are never in scope. Two guards make that
explicit: `resolve_project()` never resolves a worktree to the main project, and
the database drop refuses to touch the main checkout's database.

### Shutting everything down

Worktrees first, then the main checkout. The order is not cosmetic: worktree
containers are attached to the **main** project's network, so `sail down` in the
main checkout cannot remove it.

```
Network laravel-worktrees_sail  Removing
Network laravel-worktrees_sail  Resource is still in use
```

Compose removes main's own containers anyway and **exits 0** — that warning is a
single line in a wall of output. You are left with an orphaned network and a
worktree container still running against a database, cache and mail server that no
longer exist, so it serves 500s that read like an application bug.

```bash
bin/worktree-sail down --all   # every worktree first
sail down                      # then the shared services
```

Both from the main checkout, since `down` takes a name or `--all`.

`sail down` keeps the volumes, so every database survives; `sail down -v` destroys
them. `sail stop` is the lighter option when you only want the resources back and
intend to return shortly.

Done in the wrong order, recovery costs nothing: take the worktree down,
`docker network rm laravel-worktrees_sail`, then bring both back up.

### When Claude Code removes the worktree for you

Claude Code removes a worktree on its own when you exit a session that created
one with `--worktree`, when a subagent finishes, and when the periodic sweep
collects an old background-session worktree. It deletes the directory and the
branch; it knows nothing about the container or the database, so those are left
behind — one set per branch, quietly accumulating.

Clean up afterwards with:

```bash
bin/worktree-sail teardown .claude/worktrees/<name>
```

That works *after the fact*. `teardown` derives the Compose project and database
name from the directory name the same way `init` did, so neither the directory
nor its `.env` has to still exist.

Using `bin/worktree-sail remove <name>` instead avoids the situation entirely,
since it tears down Docker and the database before removing the worktree.

### Why not a WorktreeRemove hook?

Claude Code has `WorktreeCreate` and `WorktreeRemove` hooks, and a
`WorktreeRemove` hook calling `teardown` would close the gap above
automatically. It does not work, and both halves are worth knowing:

- **`WorktreeCreate` replaces git worktree creation** rather than supplementing
  it. The documentation is explicit that `.worktreeinclude` is then not processed
  at all, and a hook-created worktree also loses the marker Claude Code writes
  into git metadata, so the cleanup sweep never collects it. Adopting it means
  reimplementing base-branch selection, PR branching, the symlink refusals and
  filter-driver neutralisation. Not worth it.
- **`WorktreeRemove` does not fire for a worktree Claude Code created with git.**
  Tested directly on Claude Code v2.1.226: a real `claude --worktree` session was
  driven to exit, it reported `Cleaning up worktree (no pending changes)…`, and
  the worktree directory and branch were gone afterwards — but the hook never
  ran. A `SessionStart` hook configured alongside it *did* fire in that same
  session, so hooks were loading and executing; only `WorktreeRemove` stayed
  silent. It appears to be reserved for worktrees a `WorktreeCreate` hook made,
  which matches the documentation presenting the pair under "non-git version
  control".

One incidental finding from that test: hooks in a project's
`.claude/settings.json` did not run at all in a fresh session, while the same
hooks in `~/.claude/settings.json` did. Project-scoped hooks need the workspace
trust or approval that a scripted session never grants — worth remembering when
a project hook seems to do nothing.

## Working in parallel

Worktrees are meant to build and test side by side, so the tooling keeps them from
racing, starving or reaching into each other:

- **One short lock.** Allocating ports, starting the shared services and adding
  the worktree (which fetches) run under `<git dir>/worktree-sail.lock`. Each of
  those is quick; containers, migrations and installs run outside it, in
  parallel. A lock left by a run that died is noticed by its pid and cleared; a
  run started by the holder itself (a git hook calling back in) does not wait for
  it. A waiter gives up after `WORKTREE_LOCK_TIMEOUT` seconds (default 600). git
  never prompts for a password while the lock is held.
- **Memory ceilings.** Every app container — main checkout and worktrees — has
  `mem_limit` set from `SAIL_CONTAINER_MEM_LIMIT` (default `5g`) and no swap past
  it. All containers share one Docker VM; without a ceiling, one runaway test run
  takes memory from every other worktree. Over the ceiling, a process in that
  container is killed (exit 137) and nothing else is touched.
  `SAIL_CONTAINER_CPUS` adds a CPU ceiling when you want one.
- **Cheaper PHP runs.** opcache is on for the command line and pcov off, through
  an ini file in `/etc/sail/php` that `PHP_INI_SCAN_DIR` adds — a path without the
  PHP version in it, so a Sail upgrade does not orphan it.
- **No crosstalk.** A queue worker reads only keys with its own `REDIS_PREFIX`, so
  it never takes another worktree's jobs; databases and buckets are per worktree.
  So is the cache database, so `cache:clear` in one worktree leaves the others'
  caches -- and the restart signal their queue workers watch -- alone.

`compose.worktree.yaml` carries the container settings for worktrees and
`compose.override.yaml` the same ones for the main checkout (a worktree's explicit
`-f` suppresses the override file). Keep the two in step.

## Running more than one project

Nothing here is per-machine-global except the published ports, and those are the
one thing two projects will fight over. Give each project its own band rather than
relying on detection, which cannot see a project while it is stopped.

Set the two bases in each project's **main** `.env`; worktrees allocate upwards
from them:

```dotenv
# company-b/.env
WORKTREE_APP_PORT_BASE=8101
WORKTREE_VITE_PORT_BASE=5274
```

Then move the shared services out of the way with Sail's own `FORWARD_*`
variables, which is all `sail up -d` needs — the containers still reach each other
by service name over the project's own network, so only host access changes.

| | Project A (defaults) | Project B |
| --- | --- | --- |
| `APP_PORT` (main) | `80` | `8100` |
| worktree app ports | `8001…` | `8101…` |
| `VITE_PORT` (main) | `5173` | `5273` |
| worktree Vite ports | `5174…` | `5274…` |
| `FORWARD_DB_PORT` | `5432` / `3306` | `5433` / `3307` |
| `FORWARD_REDIS_PORT` | `6379` | `6380` |
| `FORWARD_MAILPIT_PORT` / `_DASHBOARD_PORT` | `1025` / `8025` | `1026` / `8026` |

A band of 100 means you never have to guess a worktree limit. One edge: `8025`
(Mailpit's dashboard) sits inside project A's `8001–8099` band, so it would matter
at around 25 simultaneous worktrees — the allocator skips it while Mailpit is
running, but move the dashboards to `18025`/`18026` if you expect to get there.

The Compose project name comes from each project's directory, so containers,
networks and volumes are already separate; only the ports need arranging.

### Every other Sail service

The shared-service list is not hard-coded. It is read from the main checkout's
`compose.yaml` — every service except `laravel.test` — so whatever
`sail:install --with=…` put there is started, joined and reported without editing
anything:

```bash
docker compose config --services | grep -v laravel.test
```

Databases are handled per engine. `DB_CONNECTION` decides how a worktree's
database is created and dropped:

| `DB_CONNECTION` | Per-worktree database |
| --- | --- |
| `pgsql` | `CREATE DATABASE` / `DROP DATABASE … WITH (FORCE)` |
| `mysql`, `mariadb` | `CREATE DATABASE IF NOT EXISTS` plus a `GRANT` to `DB_USERNAME` |
| `mongodb` | created on first write; dropped with `db.dropDatabase()` |
| `sqlite` | nothing to do — the file lives inside the worktree, so it is isolated already |

The remaining stateful services get a namespace instead of a database, written
into `.env` only when that service is actually installed:

| Service | Variable | Value |
| --- | --- | --- |
| Redis, Valkey, Memcached | `REDIS_PREFIX`, `CACHE_PREFIX` | `wt:<slug>:db:`, `wt:<slug>:cache:` |
| Redis, Valkey | `REDIS_CACHE_DB` | the lowest free database number |
| Meilisearch, Typesense | `SCOUT_PREFIX` | `<slug>_` |
| MinIO, RustFS | every variable in `WORKTREE_BUCKETS` (default `AWS_BUCKET`) | `<slug>`, `<slug>-public`, … |
| RabbitMQ | `RABBITMQ_QUEUE` | `<slug>_default` |

Mailpit and Selenium are shared as they are: one inbox for every checkout is
usually what you want, and Selenium holds no state.

**Buckets.** `WORKTREE_BUCKETS` lists the variables that hold bucket names. Each
gets a bucket per worktree, named after its folder plus whatever is left of the
variable's name once `AWS_` and `BUCKET` come off — `AWS_BUCKET` → `<slug>`,
`AWS_PUBLIC_BUCKET` → `<slug>-public` — cut to S3's 63 characters. `prepare`
creates them (in the main checkout too, under the names its `.env` gives), and
those listed in `WORKTREE_PUBLIC_BUCKETS` get an anonymous-read policy, the way a
public CDN bucket behaves in production. The work is done by the AWS CLI
(`WORKTREE_AWS_CLI_IMAGE`, pinned) in a throwaway container on the shared
network, so any S3-compatible server works. Credentials come from
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, defaulting to Sail's RustFS
values. The endpoint is always the Compose service itself (`http://rustfs:9000`
or `http://minio:9000`), whatever `AWS_ENDPOINT` says, so a teardown can never
reach a real bucket the application is pointed at.

Teardown reclaims the databases, the Redis/Valkey keys and the buckets. Search
indexes and RabbitMQ queues are not deleted — the prefixes keep them from
colliding, but removing them is manual.

## Tests get their own database too

Tests are the case where sharing a database actually corrupts something:
`RefreshDatabase` migrates and truncates, so two checkouts running suites at once
would tear each other's data out mid-run.

They cannot be separated the way the development database is, because
`phpunit.xml` is **tracked** — it is identical in every worktree, so it cannot
name a different database in each one. And it cannot simply be overridden: a
`<env>` entry in `phpunit.xml` is put into the process environment before Laravel
boots, and Laravel's dotenv is immutable, so it never overwrites a variable that
is already set. Whatever `phpunit.xml` names, wins.

So `phpunit.xml` names no database at all, and the name comes from
**`.env.testing`**, which Laravel loads *instead of* `.env` when `APP_ENV` is set
— and `phpunit.xml` sets `APP_ENV=testing`. That makes it per-checkout state, like
`.env`, and it is git-ignored for the same reason.

| Checkout | Development | Test |
| --- | --- | --- |
| main | `laravel` | `testing` |
| `feature-x` | `laravel_feature_x` | `laravel_feature_x_testing` |

`worktree-sail init` writes `.env.testing` as a copy of the checkout's `.env` with
only the database swapped, so it stays in step with the app key, ports and service
hosts. `prepare` creates the database; teardown drops it. The main checkout needs
the file too — run `bin/worktree-sail testing-env` there once; it reuses the
`testing` database Sail's own init script already creates.

It is a **copy**, not an overlay — Laravel reads `.env.testing` *instead of*
`.env`, so a file holding only `DB_DATABASE` would leave the run with no app key,
no database host and no prefixes. That also makes it a snapshot: edit `.env`
afterwards — a new port, a rotated key, a credential for a service you just
added — and the test environment keeps the old values until it is regenerated.

```bash
bin/worktree-sail testing-env
```

`init` and `up` regenerate it, so a worktree heals itself the next time you start
it. The main checkout has no such trigger, so that is the one place to run it by
hand after changing `.env`. The symptom of forgetting is a test run that behaves
as though your edit never happened.

Because `.env.testing` carries the whole environment, a missing one is dangerous:
Laravel falls back to `.env` and the suite would run against that checkout's
*development* database, which `RefreshDatabase` would wipe. `Tests\TestCase`
refuses to run when the database name does not end in `testing`, and says how to
fix it.

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

**`shared network 'laravel-worktrees_sail' is missing`** — the main checkout is
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

# laravel-worktrees

One isolated **Laravel Sail** environment per git worktree. Every checkout — the
main one and each worktree — gets its own application container, its own port and
its own databases, while a single Postgres, Redis and Mailpit are shared between
all of them.

The point is the split: **processes are shared, state is not.** Duplicating the
whole stack per branch costs four containers and a fresh database server each
time; sharing everything means two branches corrupt each other's data. This sits
in between, deliberately.

> ### Sail only
>
> This is built entirely on Laravel Sail's own extension points — the `SAIL_FILES`
> environment variable, the `compose.yaml` that `sail:install` generates, and
> per-checkout `.env` values. It does not apply to Herd, Valet, `artisan serve`,
> or a hand-rolled Docker setup. If your project doesn't run on Sail, the ideas
> may transfer but none of the code will.
>
> The generated `compose.yaml` is **never edited** — that is a hard constraint of
> the design, so `sail:install` stays free to regenerate it.

## The shape of it

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
```

| | Shared by every checkout | Its own, per checkout |
| --- | --- | --- |
| Containers | Postgres, Redis, Mailpit | the `laravel.test` app container |
| Ports | 5432 · 6379 · 1025/8025 | `APP_PORT` from 8001, `VITE_PORT` from 5174 |
| Database | the Postgres **server** | `laravel_<name>` and `laravel_<name>_testing` |
| Redis / Valkey | the **instance** | its own key prefix, so cache, queues, sessions and locks never cross, and its own cache database, so `cache:clear` clears only its own cache |
| S3 (RustFS, MinIO) | the **server** | its own buckets, created and removed with it |

## Getting started

```bash
git clone https://github.com/davidmajoulian/laravel-worktrees.git
cd laravel-worktrees

cp .env.example .env
composer install
npm install

sail up -d                     # builds the image the first time; owns the shared services
sail artisan key:generate
sail artisan migrate
bin/worktree-sail testing-env  # writes .env.testing for the main checkout
```

`.env` and `.env.testing` are deliberately git-ignored — they hold each
checkout's own ports, database names and key prefixes, which is the whole point —
so those last steps are what a fresh clone needs and a worktree gets generated for
it automatically.

Then give any branch its own environment:

```bash
bin/worktree-sail create feature/12-login     # lands in .claude/worktrees/12-login
```

Seconds later that worktree is serving on its own port, branched from the
remote's default branch, with dependencies cloned, its databases and buckets
created and migrations run. Creating a
worktree through Claude Code's own worktree feature works too: `.worktreeinclude`
carries `.env`, `vendor/` and `node_modules/` across, and the `./sail` shim
configures the worktree the first time you run any `sail` command in it.

Open `/status` on any two checkouts side by side to see it: the Postgres address,
Redis run id and Mailpit address match, while the container, database, row counts
and key prefixes do not.

## Any Sail service, and more than one project

The shared-service list is read from your `compose.yaml`, so whatever
`sail:install --with=…` installed is handled without touching the script. Each
worktree gets its own database (Postgres, MySQL, MariaDB or MongoDB — SQLite is
already per-worktree), plus its own key prefix, Scout prefix, bucket or queue for
Redis, Valkey, Memcached, Meilisearch, Typesense, MinIO, RustFS and RabbitMQ.
Mailpit and Selenium are shared as-is.

Running two projects on one machine? Give each its own port band in the main
`.env` — port detection can't see a project while it's stopped:

```dotenv
WORKTREE_APP_PORT_BASE=8101
WORKTREE_VITE_PORT_BASE=5274
```

See [Running more than one project](docs/worktree-isolation.md#running-more-than-one-project).

## Working in parallel

Several worktrees are meant to run, build and test at the same time — by hand or
by agents — without one slowing down or breaking another:

- **No races.** Port allocation, starting the shared services and adding the
  worktree run under one short lock in the shared git directory, so two `create`s
  started together get different ports. Everything slow runs side by side.
- **No starvation.** Each app container has a memory ceiling (5 GB by default,
  `SAIL_CONTAINER_MEM_LIMIT`); a run that blows it is killed alone, and the rest
  carry on. A CPU ceiling is available too (`SAIL_CONTAINER_CPUS`).
- **Less CPU per run.** opcache is on and pcov off for the PHP command line, which
  cut one test suite from 40s to 33s.
- **No crosstalk.** Databases, key prefixes and buckets are per worktree, so one
  worktree's queue worker never picks up another's jobs. Each worktree's cache has
  a Redis/Valkey database of its own, since `cache:clear` empties a whole one.
- **Nothing left behind.** `destroy` and `remove` drop the databases (Laravel's
  parallel-test ones included), flush the keys in every logical database, delete
  the buckets — and refuse to report success while anything is still there.

## Commands

| Command | What it does |
| --- | --- |
| `bin/worktree-sail create <branch> [base]` | worktree (from the remote's default branch) + dependencies + config + databases + buckets + container + migrations |
| `bin/worktree-sail up [name\|--all]` | configure and start a worktree (idempotent) |
| `bin/worktree-sail down [name\|--all]` | stop and remove a worktree's container |
| `bin/worktree-sail status` | every checkout, its port, state and database |
| `bin/worktree-sail destroy [name\|--all]` | everything `down` does, plus its databases, keys and buckets |
| `bin/worktree-sail remove <name> [--branch]` | tear down Docker, databases, keys, buckets and the worktree |
| `bin/worktree-sail prepare` | in the main checkout: start the shared services, create its databases and buckets |
| `bin/worktree-sail teardown <path>` | Docker, database and bucket cleanup only, for a worktree already deleted |
| `bin/worktree-sail testing-env` | (re)write `.env.testing`; needed once in the main checkout |

A worktree's name is its folder, which is the branch after its last slash
(`feature/12-login` → `12-login`); commands that take a name accept the branch
too.

The main checkout stays plain Sail: `sail up -d`, `sail down`, `sail test`.

### Settings (main checkout's `.env`)

| Variable | Default | What it does |
| --- | --- | --- |
| `WORKTREE_APP_PORT_BASE`, `WORKTREE_VITE_PORT_BASE` | `8001`, `5174` | where port allocation starts |
| `WORKTREE_BASE_BRANCH` | the remote's default branch | what `create` branches from |
| `WORKTREE_BUCKETS` | `AWS_BUCKET` | variables holding bucket names; each gets a per-worktree bucket |
| `WORKTREE_PUBLIC_BUCKETS` | — | which of those allow anonymous reads (like a public CDN bucket) |
| `WORKTREE_EXTRA_DATABASE_SUFFIXES` | — | databases your own tooling derives from a worktree's name, dropped with it |
| `WORKTREE_POST_CREATE` | — | a command run inside each new worktree after it is up |
| `SAIL_CONTAINER_MEM_LIMIT` | `5g` | memory ceiling of each app container |
| `SAIL_CONTAINER_CPUS` | none | CPU ceiling of each app container |
| `WORKTREE_LOCK_TIMEOUT` | `600` | seconds a run waits for another to release the lock |
| `WORKTREE_REDIS_DATABASES` | `16` | how many numbered databases the Redis/Valkey server has; each worktree's cache takes one |
| `SAIL_BIND_ADDRESS` | `127.0.0.1` | where the app and Vite ports listen; `0.0.0.0` opens them to the network |

Settings are read from the main checkout's `.env`, except `SAIL_BIND_ADDRESS` and
the two `SAIL_CONTAINER_*` ceilings: Compose reads those from each checkout's own `.env`,
which a worktree copied when it was created — set them before creating worktrees,
or in each worktree's `.env`. `WORKTREE_POST_CREATE` runs for `create` only, not
for worktrees Claude Code makes itself.

## Installing this into your own project

There's a Claude Code skill that does the whole install — working out a free port
band, copying the files, patching `phpunit.xml` and `tests/TestCase.php`, and
booting a throwaway worktree to prove it before reporting success:

```bash
cp -R skills/laravel-sail-worktrees ~/.claude/skills/
```

Then ask Claude, from your own Sail project, to set it up so each branch gets its
own environment. See [skills/README.md](skills/README.md). Prefer to do it by
hand? The tutorial below is the same procedure, written out.

## Tests

The tooling has its own suite, which drives real Docker against a throwaway copy
of this repository on a port band of its own (it never touches your projects):

```bash
composer install
bats tests/worktree-sail                    # everything; full.bats builds the Sail image once
bats tests/worktree-sail/isolation.bats     # one area
```

CI runs it on pushes to `main` and on every pull request, alongside shellcheck.

## Documentation

- **[docs/building-it-from-scratch.md](docs/building-it-from-scratch.md)** — build
  it yourself, in ten steps, with the reasoning at each decision and the
  approaches that look right but don't work.
- **[docs/worktree-isolation.md](docs/worktree-isolation.md)** — the reference:
  commands, the four mechanisms, test databases, teardown, troubleshooting.

The commit history is ordered to be read from the first commit onwards:

```bash
git log --reverse --patch
```

It starts at a stock `composer create-project` + `sail:install`, and each commit
after that adds one piece of the setup and explains why.

## Requirements

Docker, PHP, Composer and Node on the host, and the usual Sail alias:

```bash
alias sail='sh $([ -f sail ] && echo sail || echo vendor/bin/sail)'
```

Optionally, a shorthand for the worktree commands. A function rather than an alias
so it works from any subdirectory and explains itself in projects that don't have
the tooling:

```bash
wt() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "wt: not inside a git repository" >&2; return 1
  }
  [ -x "$root/bin/worktree-sail" ] || {
    echo "wt: no bin/worktree-sail in $root -- worktree isolation is not installed here" >&2
    return 1
  }
  "$root/bin/worktree-sail" "$@"
}
```

Then `wt create my-feature`, `wt status`, `wt remove my-feature`.

`up`, `down` and `destroy` take an optional worktree name, so you can drive the
whole lifecycle from the main checkout without changing directory — `wt up
my-feature`, `wt down --all`. With no name they act on the worktree you are
standing in, and from the main checkout they say so rather than guessing.

Note that `sail` and `bin/worktree-sail` stay separate on purpose. The `./sail`
shim passes every argument straight to Sail, so `sail create my-feature` does not
reach this tooling — Sail forwards unknown commands to `docker compose`, where
`create` is a real command that means something else entirely. Keeping them apart
means `sail down` in a script still means exactly what Sail says it means.

Docker Compose 2.24.4 or newer (for `!override`). macOS or Linux. Port allocation uses `lsof`, and the dependency copy uses `cp -c`
(an instant APFS clone on macOS, falling back to a plain copy elsewhere).

Built against Laravel 13, Sail 1.67, PHP 8.5 and Postgres 18, but nothing here is
version-specific — `compose.worktree.yaml` inherits the app service from whatever
`sail:install` wrote.

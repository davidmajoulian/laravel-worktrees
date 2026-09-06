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
| Redis | the Redis **instance** | its own key prefix |

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
bin/worktree-sail create my-feature
```

About seven seconds later that worktree is serving on its own port, with
dependencies cloned, its databases created and migrations run. Creating a
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

## Commands

| Command | What it does |
| --- | --- |
| `bin/worktree-sail create <branch> [base]` | worktree + dependencies + config + databases + container + migrations |
| `bin/worktree-sail up` | configure and start the current worktree (idempotent) |
| `bin/worktree-sail status` | every checkout, its port, state and database |
| `bin/worktree-sail remove <name> [--branch]` | tear down Docker, databases and the worktree |
| `bin/worktree-sail teardown <path>` | Docker and database cleanup only, for a worktree already deleted |
| `bin/worktree-sail testing-env` | (re)write `.env.testing`; needed once in the main checkout |

The main checkout stays plain Sail: `sail up -d`, `sail down`, `sail test`.

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

Note that `sail` and `bin/worktree-sail` stay separate on purpose. The `./sail`
shim passes every argument straight to Sail, so `sail create my-feature` does not
reach this tooling — Sail forwards unknown commands to `docker compose`, where
`create` is a real command that means something else entirely. Keeping them apart
means `sail down` in a script still means exactly what Sail says it means.

macOS or Linux. Port allocation uses `lsof`, and the dependency copy uses `cp -c`
(an instant APFS clone on macOS, falling back to a plain copy elsewhere).

Built against Laravel 13, Sail 1.67, PHP 8.5 and Postgres 18, but nothing here is
version-specific — `compose.worktree.yaml` inherits the app service from whatever
`sail:install` wrote.

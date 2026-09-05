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

## Quick start

Start the main checkout the ordinary Sail way — it owns the shared services:

```bash
sail up -d
```

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

macOS or Linux. Port allocation uses `lsof`, and the dependency copy uses `cp -c`
(an instant APFS clone on macOS, falling back to a plain copy elsewhere).

Built against Laravel 13, Sail 1.67, PHP 8.5 and Postgres 18, but nothing here is
version-specific — `compose.worktree.yaml` inherits the app service from whatever
`sail:install` wrote.

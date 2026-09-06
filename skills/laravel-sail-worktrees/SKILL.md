---
name: laravel-sail-worktrees
description: >-
  Install per-worktree Laravel Sail isolation into an existing Sail project, so every git
  worktree gets its own application container, ports and databases while one Postgres/MySQL,
  Redis and Mailpit are shared between them all. Use this whenever someone wants to work on
  several branches of a Laravel app at the same time, run parallel sessions or agents whose
  containers would otherwise fight over ports, keep branches from trampling each other's
  database, set up git worktrees for a Sail project, or add a second Laravel project's
  worktrees to a machine that already has one. Reach for it even when they never say
  "worktree" and only describe the symptoms: "port is already allocated" from Sail, two
  branches sharing one database, or wanting a separate environment per feature.
---

# Per-worktree Sail environments

This installs a small toolchain into an existing Laravel Sail project. Afterwards:

```bash
bin/worktree-sail create my-feature   # worktree + deps + database + container, ~7s
bin/worktree-sail status              # every checkout, its port and database
bin/worktree-sail remove my-feature   # tear all of it back down
```

Each checkout gets its own app container, `APP_PORT`/`VITE_PORT`, Compose project,
database and cache prefix. Postgres, Redis and Mailpit stay shared — one set of
containers for the whole project. Processes are shared; state is not.

Upstream, with the full reasoning: https://github.com/davidmajoulian/laravel-worktrees

## What makes this work, in one paragraph

Sail reads `SAIL_FILES` from `.env` and turns it into `-f` arguments. Once an
explicit `-f` is passed, Compose stops loading the project's own compose file — so
a worktree's project contains *only* the app service that `compose.worktree.yaml`
declares, and the backing services cannot be started a second time. That worktree
service `extends` the real one from the project's compose file (so it inherits PHP
version, volumes and port variables) and joins the main checkout's network as an
external network, which is what makes `pgsql`, `redis` and `mailpit` resolve inside
it. Everything else is `.env` values. **The project's own compose file is never
edited** — keep it that way, so `sail:install` stays free to regenerate it.

## Install it

Work through these in order. Several steps depend on facts gathered in step 1, so
don't skip ahead.

### 1. Establish the facts

Refuse to guess at any of these — a wrong answer here produces an install that
looks fine and silently isn't.

```bash
git rev-parse --show-toplevel          # must be a git repo; work from the root
git rev-parse HEAD                     # ...with at least one commit
ls compose.yaml docker-compose.yml 2>/dev/null   # which filename does this Sail use?
grep -E '^(DB_CONNECTION|DB_DATABASE|DB_USERNAME|APP_PORT|COMPOSE_PROJECT_NAME)=' .env
docker compose config --services       # which services are installed
```

- **Not a git repo, or no commits yet** — likely a brand-new project, since
  `composer create-project` does not run `git init`. Worktrees are git worktrees,
  and `git worktree add` branches from a commit, so run `git init` and make an
  initial commit before installing.
- **No compose file, or no `vendor/laravel/sail`** — this project isn't on Sail.
  Say so and stop; the whole design hangs off Sail's `SAIL_FILES` hook and none of
  it transfers to Herd, Valet or a hand-rolled Docker setup.
- **`docker-compose.yml` rather than `compose.yaml`** (older Sail) — remember it.
  Both the `extends.file` inside `compose.worktree.yaml` and the `SAIL_FILES` value
  must name the file that actually exists.
- **No `.env`** — the project has never been set up. Run `cp .env.example .env`
  and `sail artisan key:generate` first, or the install has nothing to work from.
  Check what that copy produced before trusting it: `sail:install` rewrites `.env`
  but never `.env.example`, so many Sail projects still have Laravel's stock
  example describing sqlite with `REDIS_HOST=127.0.0.1`. Copying that gives a
  config which cannot reach any container, and the app 500s with Compose warning
  that `DB_DATABASE` is unset. Fix `.env` to match the services in the compose
  file before going further.
- **`DB_CONNECTION`** decides how per-worktree databases get made. Postgres, MySQL,
  MariaDB and MongoDB are handled; `sqlite` needs no database work at all because
  its file already lives inside the worktree.

### 2. Choose a port band

This is the one genuinely non-mechanical decision, and the one that bites later if
you get it wrong.

Port detection inside the tool cannot save you here: **a stopped container reports
no published ports**, so nothing can see another project while that project is
down. Two projects that both allocate from 8001 will collide the first time one is
started while the other is stopped.

So pick a band that is this project's alone:

```bash
docker ps --format '{{.Ports}}'        # what is published right now
lsof -nP -iTCP -sTCP:LISTEN | awk '{print $9}' | grep -oE '[0-9]+$' | sort -un | tail -20
```

- First Sail project on the machine: use the defaults — main on `APP_PORT=80`,
  worktrees from `8001`, Vite from `5174`.
- Any project after that: take the next free hundred — `8101`/`5274`, then
  `8201`/`5374` — and also move the shared services out of the way with Sail's own
  `FORWARD_*` variables, since two Postgres containers cannot both publish 5432.
  The full table of those variables is in `references/ports.md`.

Tell the user which band you picked and why. If they already have a scheme, use
theirs.

### 3. Copy the files in

Four files, none of which touch anything Sail generated:

```bash
mkdir -p bin
cp <skill>/assets/worktree-sail      bin/worktree-sail   && chmod +x bin/worktree-sail
cp <skill>/assets/compose.worktree.yaml compose.worktree.yaml
cp <skill>/assets/worktreeinclude    .worktreeinclude
```

The fourth is a `sail` shim at the project root. The conventional Sail alias
(`sh $([ -f sail ] && echo sail || echo vendor/bin/sail)`) prefers it, which makes
it the one place every `sail` command passes through; in a worktree it configures
the worktree before handing over. **If the project already has a root `sail` file,
do not overwrite it** — show the user both and let them merge.

```bash
[ -e sail ] || { cp <skill>/assets/sail sail && chmod +x sail; }
```

If the project's compose file is `docker-compose.yml`, fix the reference inside
`compose.worktree.yaml` to match.

### 4. Patch the project's own files

Three small, conditional edits. Check each before making it — these files vary
between projects far more than the ones above.

**`.gitignore`** — add if absent:

```gitignore
/.claude/worktrees/
.env.testing
```

Worktrees land inside the repo, and `.env.testing` is per-checkout state exactly
like `.env`.

**`phpunit.xml`** — remove this line if it is present:

```xml
<env name="DB_DATABASE" value="testing"/>
```

`phpunit.xml` is tracked, so it is identical in every worktree and cannot name a
different database in each. It also cannot be overridden: PHPUnit pushes `<env>`
entries into the process environment before Laravel boots, and Laravel's dotenv is
immutable, so whatever `phpunit.xml` names wins over any `.env` file. Removing it
lets `.env.testing` — which Laravel loads *instead of* `.env` when `APP_ENV` is
set — carry a per-checkout name. If the project's tests already run on sqlite
`:memory:`, leave `phpunit.xml` alone; they are isolated already.

**`tests/TestCase.php`** — add a guard to `setUp()`. Removing the `phpunit.xml`
default opens a trapdoor: with no `.env.testing`, Laravel falls back to `.env` and
the suite runs against that checkout's *development* database, which
`RefreshDatabase` then wipes. The guard is what stops that being a silent disaster.

```php
protected function setUp(): void
{
    parent::setUp();

    $database = DB::connection()->getDatabaseName();

    if ($database !== ':memory:' && ! str_ends_with($database, 'testing')) {
        $this->fail("Refusing to run tests against the database [{$database}].");
    }
}
```

Insert it into whatever is already there rather than replacing the file — many
projects have real content in `TestCase.php`. Add the `Illuminate\Support\Facades\DB`
import.

### 5. Write the `.env` block

Append the *values* to the **main checkout's** `.env` — they are per-machine, and
`.env.example` is shared:

```dotenv
COMPOSE_PROJECT_NAME=<project-dir-name>
APP_PORT=<from step 2>
VITE_PORT=<from step 2>
WORKTREE_APP_PORT_BASE=<from step 2>
WORKTREE_VITE_PORT_BASE=<from step 2>
```

`COMPOSE_PROJECT_NAME` pins the network name (`<project>_sail`) that worktrees join,
so it stops depending on what the directory happens to be called. Only add the two
`WORKTREE_*` lines when the band is not the default.

Then add the same keys to `.env.example`, commented out, with a line saying what
they are for. The values belong in `.env`, but a teammate cloning the repo has only
`.env.example` to learn from — and since `.env` is git-ignored, an undocumented
knob is one nobody else will ever discover.

Then generate the test environment for the main checkout, which needs one for the
same reason a worktree does:

```bash
bin/worktree-sail testing-env
```

### 6. Prove it works

Do not report success from having copied files. Run it:

```bash
sail up -d                            # the main checkout owns the shared services
bin/worktree-sail create smoke-test
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:<worktree port>
bin/worktree-sail status
bin/worktree-sail remove smoke-test --branch
```

A healthy install shows the main checkout and the worktree on different ports with
different databases, one set of backing containers, and a clean removal that drops
the worktree's databases and leaves the main checkout's alone.

If `sail up -d` reports a port already allocated, step 2's band was wrong — pick
another and update `.env`.

### 7. Report what you did

Tell the user the port band, the databases each checkout will get, the files added
and the files patched, and the three commands they will actually use. Point them at
the upstream repo for the reasoning.

Worth mentioning once: `./sail` passes everything straight through to Sail, so it
does not expose `worktree-sail`'s commands — `sail create x` reaches
`docker compose create`, which means something else. If they want a shorthand,
the upstream README has a `wt` shell function that resolves the repository root
itself.

## References

- `references/ports.md` — every Sail service's `FORWARD_*` variable and default
  port, for laying out bands across projects.
- `references/troubleshooting.md` — the failure modes worth recognising, and what
  each one means.

# Building it from scratch

A walkthrough of how this setup is put together, in the order you would build it,
with the reasoning at each decision — including the approaches that look right
and are not. If you only want to *use* it, read
[worktree-isolation.md](worktree-isolation.md) instead.

The goal: **one Laravel Sail application container per git worktree, all sharing
one Postgres, one Redis and one Mailpit.**

Two constraints shape every decision below:

1. **Never edit the `compose.yaml` that Sail generates.** It should stay
   regenerable by `sail:install`, so upgrades and added services keep working.
2. **Never start a second copy of a backing service.** Four containers per branch
   is what we are trying to avoid.

Everything else follows from those two.

---

## Step 1 — A Laravel app with Sail

```bash
composer create-project laravel/laravel .
composer require laravel/sail --dev
php artisan sail:install --with=pgsql,redis,mailpit
```

`sail:install` does two things worth knowing about. It writes a Compose file —
**`compose.yaml`** on Sail 1.4x and newer, `docker-compose.yml` on older
versions; use whichever name your install produced everywhere below. And it
rewrites `.env` so `DB_HOST=pgsql`, `REDIS_HOST=redis`, `MAIL_HOST=mailpit`,
which are Compose service names resolved by Docker's internal DNS.

Open the generated file and find these four lines, because each one comes back
later:

```yaml
        image: 'sail-8.5/app'                                   # ① shared image name
        ports:
            - '${APP_PORT:-80}:80'                              # ② port from .env
            - '${VITE_PORT:-5173}:${VITE_PORT:-5173}'
        networks: [sail]                                        # ③ project-local network
        depends_on: [pgsql, redis, mailpit]                     # ④ in the way, later
```

Start it and confirm you have a working baseline:

```bash
sail up -d
curl -s -o /dev/null -w '%{http_code}\n' http://localhost   # 200
```

> The first `sail up -d` builds the PHP image and pulls three others. If a pull
> hangs on `error getting credentials`, that is Docker Desktop's credential
> helper, not your setup — see the troubleshooting section of the reference doc.

---

## Step 2 — Pin the Compose project name

By default Docker Compose names the project after the directory, and names the
network `<project>_sail`. Worktrees are going to attach to that network by name,
so make it predictable rather than a function of what the folder is called. Add
to **`.env`** (not `.env.example` — this is per-machine):

```dotenv
COMPOSE_PROJECT_NAME=laravel-worktrees
APP_PORT=80
VITE_PORT=5173
```

Compose reads `COMPOSE_PROJECT_NAME` out of `.env` itself, so nothing else has to
pass it. Prove it:

```bash
docker compose config | head -1        # name: laravel-worktrees
docker network ls | grep sail          # laravel-worktrees_sail
```

`APP_PORT`/`VITE_PORT` are already the defaults; writing them down explicitly
gives the tooling something to compare a worktree's values against later.

---

## Step 3 — Decide what "isolated" actually means

Before writing any config, settle this, because everything else is downstream:

| | Shared | Isolated |
| --- | --- | --- |
| Postgres **server** | ✅ one container | |
| Postgres **database** | | ✅ one per checkout |
| Postgres **test database** | | ✅ one per checkout |
| Redis **server** | ✅ one container | |
| Redis **keyspace** | | ✅ one prefix per checkout |
| Mailpit | ✅ one inbox | |
| App container | | ✅ one per checkout |
| Ports | | ✅ one set per checkout |

**Processes are shared, state is not.** Two alternatives, and why they lose:

- *Duplicate everything per worktree.* Four containers and a fresh Postgres
  volume per branch. Slow to start, heavy on RAM, and every branch needs its own
  migrate-and-seed cycle.
- *Share everything including the database.* One container each, but two branches
  with different migrations corrupt each other immediately.

Sharing the server while separating the database gives you nearly all the
resource win with none of the interference. A database is cheap; a Postgres
server is not.

---

## Step 4 — Give worktrees their own Compose file

Here is the problem. A worktree checks out the same tracked `compose.yaml`. Run
`sail up -d` in it and Compose reads that file, which declares four services — so
you get a second Postgres, a second Redis, a second Mailpit, all fighting for
ports 5432/6379/8025.

### What does not work

**A `compose.override.yml` in the worktree.** Compose overrides can add and
modify services. They cannot *remove* them. There is no way to say "ignore
pgsql".

**Profiles.** Tagging pgsql/redis/mailpit with a profile looks promising, but
`laravel.test` has `depends_on` on all three, and modern Compose auto-enables the
profiles of anything a started service depends on. The services come back.

**Clearing `depends_on` in an override.** Compose normalises `depends_on` into a
map and merges maps, so `depends_on: []` merges into the base value and changes
nothing.

### What does work

Sail has exactly the hook needed. From `vendor/laravel/sail/bin/sail`:

```bash
export SAIL_FILES=${SAIL_FILES:-""}
...
if [ -n "$SAIL_FILES" ]; then
    IFS=':' read -ra SAIL_FILES <<< "$SAIL_FILES"
    for FILE in "${SAIL_FILES[@]}"; do COMPOSE_CMD+=(-f "$FILE"); done
fi
```

Sail sources `.env`, then turns `SAIL_FILES` into `-f` arguments. And **once an
explicit `-f` is passed, Compose stops auto-loading `compose.yaml`.** That is the
whole trick: a worktree's project contains only what its own file declares, so
the backing services are not merely "not started" — they are not in the project
at all and cannot be started by accident.

Create `compose.worktree.yaml`:

```yaml
services:
    laravel.test:
        extends:
            file: compose.yaml
            service: laravel.test
        depends_on: !reset null
        networks:
            - sail

networks:
    sail:
        external: true
        name: '${SAIL_SHARED_NETWORK:-laravel-worktrees_sail}'
```

Four things are happening:

**`extends` inherits rather than copies.** Paste the service definition instead
and it goes stale the moment you run `sail:install` again or bump PHP. Inheriting
means bind mounts, port variables and Xdebug wiring track the real file. Note
that paths inside an extended service resolve relative to the extended file's
directory — which is the worktree — so `.:/var/www/html` still means "this
worktree".

**`depends_on: !reset null` is required.** `extends` *does* copy `depends_on`.
Leave it and you get:

```
service "laravel.test" depends on undefined service "pgsql": invalid compose project
```

`!reset` needs Compose 2.24+; `!override []` works too.

**`external: true` joins the main project's network.** This is what makes the
hostnames `pgsql`, `redis` and `mailpit` resolve inside a worktree's container —
they are the main checkout's containers, reachable by service alias. It also
means Compose will never delete that network when tearing a worktree down.

**The inherited `image:` is `sail-8.5/app`** — the same name the main checkout
built. So a worktree starts from an existing image instead of building its own.
This is why creating a worktree takes seconds, not minutes.

Check it before going further:

```bash
docker compose -f compose.worktree.yaml config --services   # laravel.test, and nothing else
```

---

## Step 5 — Work out what a worktree is missing

```bash
git worktree add -b feature-x .claude/worktrees/feature-x main
ls .claude/worktrees/feature-x
```

Tracked files only. No `.env`, no `vendor/`, no `node_modules/` — all git-ignored.
That last one matters more than it looks: the container bind-mounts the worktree
at `/var/www/html`, so it would boot into a directory with no
`vendor/autoload.php` and fail instantly.

Claude Code reads a **`.worktreeinclude`** file when it creates a worktree. It
matches `.gitignore`-style patterns against

```bash
git ls-files --others --ignored --exclude-standard --directory
```

and copies what matches. So:

```gitignore
.env
/vendor/
/node_modules/
/public/build/
```

Test your patterns before trusting them — the same query, restricted to your file:

```bash
git ls-files --others --ignored --directory --exclude-from=.worktreeinclude
```

If an entry you expect is missing, the usual cause is `--directory` collapsing:
a directory only appears as one entry when *everything* in it is untracked. This
is why a pattern like `/bin/somefile` inside an otherwise-untracked `bin/` will
not match, but `/bin/` will.

Copy with `cp -Rc` on macOS. `-c` clones on APFS, so `vendor/` and
`node_modules/` together take about two seconds and no additional disk. Run this
from the repository root to bring everything across:

```bash
DEST=.claude/worktrees/feature-x

git ls-files --others --ignored --directory --exclude-from=.worktreeinclude |
while IFS= read -r entry; do
    entry=${entry%/}
    mkdir -p "$DEST/$(dirname "$entry")"
    cp -Rc "$entry" "$DEST/$entry" 2>/dev/null || cp -R "$entry" "$DEST/$entry"
done
```

Claude Code runs the equivalent itself when it creates a worktree; this loop is
what you need when you make one by hand.

### Track the tooling, ignore the generated state

A decision worth making deliberately. Ignore this and never commit it:

```gitignore
/.claude/worktrees/
```

plus each worktree's `.env`, which Laravel's own `.gitignore` already covers.
That is *generated* state and has no business in a commit.

But **track** `compose.worktree.yaml`, `bin/worktree-sail` and `sail`. Tracked
tooling means `git worktree add` supplies it automatically — nothing to copy, and
no chance of per-worktree copies drifting apart. (This repo tried it the other
way first, with the tooling ignored and copied in; it needed a whole extra `sync`
command to fight the drift, and that command disappeared the moment the files
became tracked.)

---

## Step 6 — Do one worktree by hand

Automate only after you have felt the moving parts.

Step 5 already brought `.env` across. Now edit the worktree's copy of it — not
the main checkout's:

```bash
cd .claude/worktrees/feature-x
```

Pick ports nothing is already using — each of these should print nothing:

```bash
lsof -nP -iTCP:8001 -sTCP:LISTEN
lsof -nP -iTCP:5174 -sTCP:LISTEN
```

Every line below exists for a reason:

```dotenv
SAIL_FILES=compose.worktree.yaml              # use the worktree Compose file
SAIL_SHARED_NETWORK=laravel-worktrees_sail      # attach to the main project's network
COMPOSE_PROJECT_NAME=laravel-worktrees-feature-x # separate Compose project → separate containers
APP_PORT=8001                                 # separate published ports
VITE_PORT=5174
APP_URL=http://localhost:8001                 # so generated URLs match
DB_DATABASE=laravel_feature_x                 # own database on the shared server
REDIS_PREFIX=feature_x_database_              # own keyspace on the shared Redis
CACHE_PREFIX=feature_x_cache_
```

Most of those keys already exist in the copied file. Changing them in place keeps
it readable; appending also works — Docker Compose and Laravel's dotenv reader
both take the *last* occurrence of a duplicated key — but you are left looking at
the main checkout's values above your own.

`DB_HOST=pgsql`, `REDIS_HOST=redis` and `MAIL_HOST=mailpit` stay exactly as they
are — those names now resolve to the main checkout's containers across the shared
network.

`laravel-vite-plugin` already reads `VITE_PORT`, so no JS config needs touching.

The database does not exist yet. Create it on the shared server:

```bash
docker exec laravel-worktrees-pgsql-1 \
  psql -U sail -d postgres -c 'CREATE DATABASE "laravel_feature_x" OWNER "sail"'
```

Then start it:

```bash
sail up -d
sail artisan migrate
```

Checkpoint — this is the moment the whole idea either works or does not:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost        # 200, main
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8001   # 200, worktree
docker ps --format '{{.Names}}'                                  # 5 containers, not 8
```

Five containers: two apps, one Postgres, one Redis, one Mailpit.

### Its own test database

The development database is only half of it. `RefreshDatabase` migrates and
truncates, so two checkouts running tests against one database destroy each
other's runs — this is the case where sharing genuinely corrupts data.

You cannot fix it in `phpunit.xml`, for two reasons. It is tracked, so it is the
same file in every worktree. And its `<env>` entries are pushed into the process
environment before Laravel boots, while Laravel's dotenv is immutable and never
overwrites a variable that is already set — so whatever `phpunit.xml` names wins
over any `.env` file you write.

The way through is to have `phpunit.xml` name no database, and put the name in
`.env.testing`. Laravel loads `.env.<APP_ENV>` *instead of* `.env`, and
`phpunit.xml` already sets `APP_ENV=testing`, so that file is the entire
environment a test run sees — which is why it is generated as a copy of `.env`
with only `DB_DATABASE` swapped, rather than written from scratch.

Delete this line from `phpunit.xml`:

```xml
<env name="DB_DATABASE" value="testing"/>
```

add `.env.testing` to `.gitignore` beside `.env`, and generate one per checkout:

```dotenv
DB_DATABASE=laravel_feature_x_testing
```

The main checkout needs one too; it can keep the `testing` database Sail's init
script already creates.

Generate that file rather than writing it by hand, and regenerate it whenever
`.env` changes. Because Laravel reads it *instead of* `.env` it has to carry the
whole environment, which makes it a snapshot of `.env` at the moment it was
written — edit a port or rotate the app key later and the test run keeps using the
old values, with no error to tell you so. Deriving it from `.env` on every `init`
is what stops the two drifting apart.

That trade has a sharp edge worth closing. Without `.env.testing`, Laravel falls
back to `.env` and the suite runs against the checkout's *development* database,
which `RefreshDatabase` then wipes. Put a guard in `tests/TestCase.php`:

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

Check it by pointing `.env.testing` at the development database on purpose and
confirming the suite refuses.

### Migrate before you probe

Laravel's default `SESSION_DRIVER=database` means *every* request needs the
`sessions` table. Until you migrate, the app returns 500 — not a connection
error, a perfectly healthy container serving an exception. Any "wait for the app
to come up" loop written before the migration step will simply watch a broken app
for its entire timeout.

---

## Step 7 — Automate it

[`bin/worktree-sail`](../bin/worktree-sail) is step 6 in a script. Reading it in
this order makes it straightforward:

| Section | Job |
| --- | --- |
| root resolution | `--show-toplevel` for this worktree, `--git-common-dir` to find the main checkout |
| `env_get` / `env_set` | surgical `.env` edits that leave other lines alone |
| port allocation | first free port from 8001/5174 upwards |
| docker helpers | find containers by Compose label, create/drop databases |
| commands | `init`, `prepare`, `up`, `down`, `destroy`, `status`, `create`, `remove` |

Three things it has to get right, each learned the hard way:

**Ports must be checked against reality, not just against other `.env` files.**
A port is unusable if a host process is listening on it (`lsof`) *or* a running
container has it published. And it must be re-checked at start time — a port free
when the worktree was created may not be a week later.

Know what that check *cannot* do: a stopped container reports no ports at all, so
it cannot see another project while that project is down. Detection is enough
inside one project; two projects on one machine need separate port bands, which
is why the bases are read from `.env` rather than hard-coded:

```dotenv
WORKTREE_APP_PORT_BASE=8101
WORKTREE_VITE_PORT_BASE=5274
```

**Don't hard-code the list of services either.** Read it from the main checkout's
`compose.yaml` — everything except `laravel.test` — so whatever
`sail:install --with=…` added is picked up on its own:

```bash
docker compose config --services | grep -v laravel.test
```

Then branch on `DB_CONNECTION` for the database work: `psql` for Postgres,
`mysql` fed over stdin for MySQL and MariaDB (so the backtick quoting survives),
`db.dropDatabase()` for Mongo, and nothing at all for SQLite, whose file already
lives inside the worktree.

**The script resolves "which worktree" from the working directory.** So a
`create` command must invoke the child from *inside* the new worktree, not by
path, or it configures whichever worktree you happened to be standing in.

**A copied `.env` is dangerous until it is rewritten.** It still says
`COMPOSE_PROJECT_NAME=laravel-worktrees` with no `SAIL_FILES`. Run
`sail down --volumes` against that from a worktree and Compose resolves the
**main** project — deleting the main checkout's containers *and* its Postgres
volume. This repo did exactly that once. Three guards now prevent it:
`worktree_is_configured()` gates every Sail invocation, `resolve_project()` never
resolves a worktree to the main project, and the database drop refuses to touch
the main checkout's database.

---

## Step 8 — Close the copied-`.env` window

The same stale `.env` is a trap for humans too: `sail up -d` in a fresh worktree
reconciles the main project and recreates the main app container bind-mounted
onto the worktree's files.

The standard Sail alias prefers a project-local `sail` file:

```bash
alias sail='sh $([ -f sail ] && echo sail || echo vendor/bin/sail)'
```

so committing a `sail` shim at the repo root puts one checkpoint in front of
every `sail` command. It is executed with `sh`, so keep it POSIX — no bashisms:

```sh
#!/usr/bin/env sh
set -e

root=$(git rev-parse --show-toplevel 2>/dev/null) || root=''

if [ -n "$root" ]; then
    # In a linked worktree, --git-common-dir points back at the main checkout.
    main_root=$(cd "$root" && cd "$(dirname "$(git rev-parse --git-common-dir)")" && pwd -P)

    if [ "$root" != "$main_root" ] && [ -x "$root/bin/worktree-sail" ]; then
        if ! grep -q '^SAIL_FILES=compose.worktree.yaml$' "$root/.env" 2>/dev/null; then
            echo "==> this worktree is not configured for Sail yet; configuring it first" >&2
            "$root/bin/worktree-sail" prepare
        fi
    fi
fi

exec sh "${root:-.}/vendor/bin/sail" "$@"
```

`--git-common-dir` is the key line: in the main checkout it returns `.git`, whose
parent is the checkout itself, so the two paths match and the shim does nothing.
In a worktree it returns an absolute path back to the main checkout, so they
differ and the check runs.

Note that `sail up -d` starts the container but does not migrate, so a brand-new
worktree will still 500 until you run `sail artisan migrate`. Keep a
`worktree-sail up` that does the full sequence.

---

## Step 9 — Make teardown remove exactly the right things

Removing a worktree has to clean up everything it created and nothing it
borrowed. Selecting by Compose project label does that by construction:

```bash
docker ps -aq      --filter "label=com.docker.compose.project=$project"
docker network ls -q --filter "label=com.docker.compose.project=$project"
docker volume ls  -q --filter "label=com.docker.compose.project=$project"
```

The shared network and the `sail-pgsql` / `sail-redis` volumes carry the **main**
project's labels, so they are never selected. Then drop the worktree's database
and flush its Redis keys by prefix, and finally `git worktree remove`.

Verify a teardown by diffing the world before and after: only the worktree's own
container, database and keys should be gone.

Give the script a way to do this cleanup *after the fact*, deriving the Compose
project and database name from the worktree's directory name rather than reading
its `.env`. You need it because Claude Code removes worktrees on its own — at
session exit, when a subagent finishes, or through its cleanup sweep — and by
then the directory and its `.env` are gone, while the container and database are
still there.

The obvious fix is a `WorktreeRemove` hook, and it does not work: on Claude Code
v2.1.226 that hook does not fire for a worktree created with git, only for one a
`WorktreeCreate` hook made — and `WorktreeCreate` replaces git worktree creation
entirely, which costs you `.worktreeinclude` processing among much else. See
[worktree-isolation.md](worktree-isolation.md#why-not-a-worktreeremove-hook).
Until that changes, run the cleanup yourself:

```bash
bin/worktree-sail teardown .claude/worktrees/<name>
```

---

## Step 10 — Make the isolation observable

Add a page that prints what is shared and what is not — this repo uses
[`/status`](../routes/web.php). Show the Postgres server address, the Redis
`run_id` and the Mailpit address (identical across checkouts) next to the
container id, Compose project, database and row counts (all different).

Being able to *see* one Redis instance behind two prefixes turns the whole thing
from a claim into an observation, and it is the fastest way to spot a worktree
that quietly reconnected to the wrong database.

One detail: name the checkout from `IGNITION_LOCAL_SITES_PATH`, which Sail sets
to the host project directory. `base_path()` is `/var/www/html` in every
container, so using it makes every checkout call itself "html".

---

## Adapting this to your own project

- **Another database engine.** Nothing to change: `DB_CONNECTION` selects how the
  per-worktree database is created and dropped, covering Postgres, MySQL,
  MariaDB, MongoDB and SQLite.
- **Any other Sail service.** Also nothing to change: the shared-service list is
  derived from `compose.yaml`, and Meilisearch, Typesense, MinIO, RustFS and
  RabbitMQ get a per-worktree prefix, bucket or queue name when they are present.
- **A different port range.** `WORKTREE_APP_PORT_BASE` and
  `WORKTREE_VITE_PORT_BASE` in the main checkout's `.env`.
- **An existing project with real data.** Nothing here touches the main
  checkout's database. To give a worktree a copy rather than an empty schema,
  `pg_dump` the main database into the new one after `ensure_database` instead of
  running migrations.
- **A different project name.** `COMPOSE_PROJECT_NAME` in the main `.env` is the
  single source; the network name and every worktree project name derive from it.

## The traps, collected

| Trap | Symptom | Fix |
| --- | --- | --- |
| `extends` copies `depends_on` | `depends on undefined service "pgsql"` | `depends_on: !reset null` |
| Override files can't remove services | duplicate Postgres/Redis | `SAIL_FILES`, not an override |
| Session driver is `database` | app 500s on a fresh worktree | migrate *before* probing HTTP |
| Copied `.env` names the main project | `sail` hijacks or deletes main's stack | gate on `SAIL_FILES`; the `./sail` shim |
| `--directory` collapses untracked dirs | `.worktreeinclude` pattern never matches | match the directory (`/bin/`), not a file in it |
| `base_path()` in a container | every checkout is called "html" | `IGNITION_LOCAL_SITES_PATH` |
| Docker credential helper hangs | pulls stall on `error getting credentials` | restart Docker Desktop, or drop `credsStore` |
| `phpunit.xml` is tracked | every checkout tests against one shared database | name the database in `.env.testing`, not `phpunit.xml` |
| PHPUnit `<env>` beats dotenv | `.env.testing` silently ignored | remove the entry from `phpunit.xml`; it cannot be overridden |
| Claude Code removed the worktree itself | container and database orphaned | `worktree-sail teardown <path>`; a `WorktreeRemove` hook will not do it |
| Hooks in project `.claude/settings.json` | never run in a fresh session | put them in `~/.claude/settings.json`, which is trusted |
| `.env.testing` is a snapshot of `.env` | tests silently use pre-edit values | regenerate with `worktree-sail testing-env` after editing `.env` |
| A stopped container reports no ports | two projects allocate the same port | give each project a port band; detection cannot see a stopped project |

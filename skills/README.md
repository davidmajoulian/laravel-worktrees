# laravel-sail-worktrees (Claude Code skill)

Installs this setup into **another** Laravel Sail project: it works out the port
band, copies the files in, patches `.gitignore`, `phpunit.xml` and
`tests/TestCase.php`, writes the `.env` block, then boots a throwaway worktree to
prove the install before reporting success.

## Install

```bash
cp -R skills/laravel-sail-worktrees ~/.claude/skills/
```

It has to be a **personal** skill rather than a project one. A skill under a
project's own `.claude/skills/` only triggers while you are working inside that
project — which is precisely where you don't need this one. Copied to
`~/.claude/skills/`, it is available in the project you actually want to install
into.

## Using it

The skill installs into a project that is **already a working Laravel Sail app**.
It does not set Laravel up for you, and it never edits the compose file Sail
generates — it layers on top of one that already works.

### On an existing project

This is the usual case, and there is nothing to prepare. From inside the repo, say
what you want:

> set this project up so each branch gets its own environment

The description is written to catch that phrasing, along with the symptoms that
lead people here — Sail reporting a port already allocated, or two branches sharing
one database. You can also invoke it by name with `/laravel-sail-worktrees`.

### On a brand-new project

Get Laravel and Sail running first, exactly as the Laravel documentation says:

```bash
composer create-project laravel/laravel my-app
cd my-app
composer require laravel/sail --dev
php artisan sail:install --with=pgsql,redis,mailpit
```

Then initialise git, which `composer create-project` does not do:

```bash
git init -b main && git add -A && git commit -m "Laravel + Sail"
```

That step is easy to miss and matters: worktrees are git worktrees, and
`git worktree add` branches from a commit, so a repo with no history cannot have
one. The skill checks for this before it starts.

Now ask it to install, as above.

### What it does

It decides rather than copies — the parts that go wrong when you install by hand:

- **Which port band is free**, checking what is already running so a second or
  third project on the machine does not collide with the first.
- **Whether `phpunit.xml` needs its database line removed**, since a project whose
  tests already run on sqlite `:memory:` is isolated and should be left alone.
- **Which database engine** is in play — Postgres, MySQL, MariaDB, MongoDB or
  SQLite each need different handling, or none.
- **Whether this is an older Sail** using `docker-compose.yml` rather than
  `compose.yaml`, which changes what the worktree compose file extends.
- **Whether a root `./sail` file already exists**, which must be merged rather than
  overwritten.

It finishes by creating a throwaway worktree, booting it, and removing it again —
so it demonstrates the install instead of reporting success from having copied
files.

### Afterwards

```bash
wt create my-feature     # worktree + dependencies + databases + container
wt status                # every checkout, its port and database
wt remove my-feature     # tear all of it back down
```

`wt` is an optional shell function; the main repository's README has it. Without it
the same commands are `bin/worktree-sail create my-feature` and so on.

Note that `sail` and the worktree tooling stay separate on purpose. The `./sail`
shim passes every argument straight through to Sail, so `sail create my-feature`
does **not** reach this tooling — it lands on `docker compose create`, which is a
real command meaning something else.

## Keeping it in step

`assets/` holds copies of the four files from this repository's root, so the skill
is self-contained and installable on its own. After changing any of them here,
refresh the copies:

```bash
cp bin/worktree-sail        skills/laravel-sail-worktrees/assets/worktree-sail
cp compose.worktree.yaml    skills/laravel-sail-worktrees/assets/compose.worktree.yaml
cp sail                     skills/laravel-sail-worktrees/assets/sail
cp .worktreeinclude         skills/laravel-sail-worktrees/assets/worktreeinclude
```

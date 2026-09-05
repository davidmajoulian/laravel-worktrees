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

Then, from any Laravel Sail project: *"set this project up so each branch gets its
own environment"* — or invoke it by name with `/laravel-sail-worktrees`.

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

<?php

namespace Tests;

use Illuminate\Foundation\Testing\TestCase as BaseTestCase;
use Illuminate\Support\Facades\DB;

abstract class TestCase extends BaseTestCase
{
    /**
     * Every checkout -- the main one and each worktree -- runs its tests against
     * its own database on the shared Postgres. The name comes from .env.testing,
     * which bin/worktree-sail generates per checkout, because phpunit.xml is
     * tracked and so cannot name a different database in each worktree.
     *
     * If .env.testing is missing, Laravel falls back to .env and the suite would
     * run against this checkout's *development* database, which RefreshDatabase
     * would then wipe. Refuse rather than destroy someone's work in progress.
     */
    protected function setUp(): void
    {
        parent::setUp();

        $database = DB::connection()->getDatabaseName();

        if ($database !== ':memory:' && ! str_ends_with($database, 'testing')) {
            $this->fail(
                "Refusing to run tests against the database [{$database}]: its name does not end "
                .'in "testing", so this looks like a development database. Run '
                .'`bin/worktree-sail testing-env` in this checkout to generate .env.testing.'
            );
        }
    }
}

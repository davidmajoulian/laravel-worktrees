<?php

namespace Tests;

use Dotenv\Dotenv;
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
     * run against this checkout's *development* database. The check runs here, not
     * in setUp(): setUp() boots the traits first, and RefreshDatabase starts with
     * migrate:fresh -- by the time setUp() could object, the wrong database would
     * already have been rebuilt.
     */
    protected function setUpTraits()
    {
        $database = DB::connection()->getDatabaseName();

        if ($database !== ':memory:' && ! $this->isTestDatabase($database)) {
            $this->fail(
                "Refusing to run tests against the database [{$database}]: it is not this checkout's "
                .'test database. Run `bin/worktree-sail testing-env` in this checkout to generate .env.testing.'
            );
        }

        return parent::setUpTraits();
    }

    /**
     * Whether the database is a test database: named like one, and not this
     * checkout's development database -- a worktree folder ending in "testing"
     * gives a development database whose name ends in "testing" too.
     */
    private function isTestDatabase(string $database): bool
    {
        // Parallel testing runs each process against <database>_test_<n>.
        if (preg_match('/testing(_test_\d+)?$/', $database) !== 1) {
            return false;
        }

        $env = base_path('.env');
        $development = is_file($env) ? (Dotenv::parse((string) file_get_contents($env))['DB_DATABASE'] ?? null) : null;

        return $development === null
            || preg_match('/^'.preg_quote($development, '/').'(_test_\d+)?$/', $database) !== 1;
    }
}

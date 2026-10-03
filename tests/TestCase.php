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
     * run against this checkout's *development* database. The check runs here, not
     * in setUp(): setUp() boots the traits first, and RefreshDatabase starts with
     * migrate:fresh -- by the time setUp() could object, the wrong database would
     * already have been rebuilt.
     */
    protected function setUpTraits()
    {
        $database = DB::connection()->getDatabaseName();

        // Parallel testing runs each process against <database>_test_<n>.
        if ($database !== ':memory:' && preg_match('/testing(_test_\d+)?$/', $database) !== 1) {
            $this->fail(
                "Refusing to run tests against the database [{$database}]: its name does not end "
                .'in "testing", so this looks like a development database. Run '
                .'`bin/worktree-sail testing-env` in this checkout to generate .env.testing.'
            );
        }

        return parent::setUpTraits();
    }
}

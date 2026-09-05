<?php

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Redis;
use Illuminate\Support\Facades\Route;

Route::get('/', function () {
    return view('welcome');
});

/*
 * A diagnostics page for the worktree setup: it shows what belongs to this
 * checkout alone and what it shares with every other checkout. Open it on the
 * main checkout and on a worktree side by side -- the "shared" column matches,
 * the "isolated" column does not.
 */
Route::get('/status', function () {
    $database = DB::selectOne('select current_database() as name, inet_server_addr()::text as server');

    try {
        $redis = Redis::connection()->info();
        $redisId = $redis['run_id'] ?? data_get($redis, 'Server.run_id', 'unknown');
    } catch (Throwable $e) {
        $redisId = 'unavailable: '.$e->getMessage();
    }

    return view('status', [
        // Sail passes the host-side project directory through as
        // IGNITION_LOCAL_SITES_PATH; base_path() is always /var/www/html here.
        'checkout' => basename(env('IGNITION_LOCAL_SITES_PATH') ?: base_path()),
        'identity' => [
            'App container' => gethostname(),
            'Compose project' => env('COMPOSE_PROJECT_NAME', '(unset)'),
            'Served on' => config('app.url'),
        ],
        'shared' => [
            'Postgres server' => $database->server.'  (container "pgsql")',
            'Redis run id' => $redisId,
            'Mailpit' => gethostbyname('mailpit').'  (container "mailpit")',
        ],
        'isolated' => [
            'Database' => $database->name,
            'Rows in "users"' => DB::table('users')->count(),
            'Redis key prefix' => config('database.redis.options.prefix') ?: '(none)',
            'Cache key prefix' => config('cache.prefix') ?: '(none)',
        ],
    ]);
});

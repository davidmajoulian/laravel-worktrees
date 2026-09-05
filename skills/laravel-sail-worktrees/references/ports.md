# Sail's published ports, and laying out bands

Everything below is a host port. Containers reach each other by service name over
the project's own network, so changing these only affects access from your machine
(TablePlus, a browser, a mail client) — never the app's ability to reach its
services.

## Every service Sail can install

| Service | Variable | Default |
| --- | --- | --- |
| application | `APP_PORT` | 80 |
| Vite | `VITE_PORT` | 5173 |
| mysql / mariadb | `FORWARD_DB_PORT` | 3306 |
| pgsql | `FORWARD_DB_PORT` | 5432 |
| mongodb | `FORWARD_MONGODB_PORT` | 27017 |
| redis | `FORWARD_REDIS_PORT` | 6379 |
| valkey | `FORWARD_VALKEY_PORT` | 6379 |
| memcached | `FORWARD_MEMCACHED_PORT` | 11211 |
| meilisearch | `FORWARD_MEILISEARCH_PORT` | 7700 |
| typesense | `FORWARD_TYPESENSE_PORT` | 8108 |
| minio | `FORWARD_MINIO_PORT` / `FORWARD_MINIO_CONSOLE_PORT` | 9000 / 8900 |
| rustfs | `FORWARD_RUSTFS_PORT` / `FORWARD_RUSTFS_CONSOLE_PORT` | 9000 / 9001 |
| rabbitmq | `FORWARD_RABBITMQ_PORT` / `FORWARD_RABBITMQ_DASHBOARD_PORT` | 5672 / 15672 |
| mailpit | `FORWARD_MAILPIT_PORT` / `FORWARD_MAILPIT_DASHBOARD_PORT` | 1025 / 8025 |
| soketi | `PUSHER_PORT` / `PUSHER_METRICS_PORT` | 6001 / 9601 |
| selenium | — | none published |

Note that `redis` and `valkey` both default to 6379, and `minio` and `rustfs` both
to 9000 — a project with both installed already needs one of them moved.

## A band per project

| | Project A | Project B | Project C |
| --- | --- | --- | --- |
| `APP_PORT` | 80 | 8100 | 8200 |
| `WORKTREE_APP_PORT_BASE` | 8001 | 8101 | 8201 |
| `VITE_PORT` | 5173 | 5273 | 5373 |
| `WORKTREE_VITE_PORT_BASE` | 5174 | 5274 | 5374 |
| `FORWARD_DB_PORT` | default | +1 | +2 |
| `FORWARD_REDIS_PORT` | default | +1 | +2 |
| `FORWARD_MAILPIT_PORT` | default | +1 | +2 |
| `FORWARD_MAILPIT_DASHBOARD_PORT` | 8025 | 8026 | 8027 |

Give the project the developer uses most often port 80, so `localhost` needs no
port at all.

One edge worth knowing: 8025 (Mailpit's dashboard) sits inside project A's
8001–8099 band, so it would matter at around 25 simultaneous worktrees. The
allocator skips it while Mailpit is running; move the dashboards to 18025/18026 if
a project will realistically get there.

## Why bands rather than detection

The tool does check both `lsof` and running containers before handing a worktree a
port, and re-checks at start time. But a **stopped** container publishes nothing —
`docker ps -a` shows an empty port list for it. So detection cannot see a project
that is currently down, which is exactly when a collision gets created and only
discovered later, when that project is started again.

Detection is enough within one project, because its worktrees record their ports in
`.env` files the tool can read. Across projects, only a static band is safe.

<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{{ $checkout }} — sail worktree status</title>
    <style>
        :root {
            color-scheme: light dark;
            --bg: #f6f7f9; --card: #fff; --ink: #16181d; --muted: #6b7280;
            --line: #e4e6eb; --accent: #1b6ef3; --shared: #0a7f5f;
        }
        @media (prefers-color-scheme: dark) {
            :root { --bg: #101216; --card: #181b21; --ink: #e8eaee; --muted: #9aa1ad;
                    --line: #272b33; --accent: #6aa4ff; --shared: #3fbf98; }
        }
        * { box-sizing: border-box; }
        body { margin: 0; padding: 2.5rem 1.25rem; background: var(--bg); color: var(--ink);
               font: 15px/1.55 ui-sans-serif, -apple-system, "Segoe UI", Roboto, sans-serif; }
        .wrap { max-width: 60rem; margin: 0 auto; }
        h1 { font-size: 1.5rem; margin: 0 0 .25rem; letter-spacing: -.01em; }
        h1 code { background: var(--accent); color: #fff; padding: .1em .4em; border-radius: .35rem; }
        p.lede { margin: 0 0 2rem; color: var(--muted); }
        .grid { display: grid; gap: 1rem; grid-template-columns: repeat(auto-fit, minmax(17rem, 1fr)); }
        section { background: var(--card); border: 1px solid var(--line); border-radius: .75rem; padding: 1.1rem 1.25rem; }
        h2 { font-size: .78rem; text-transform: uppercase; letter-spacing: .07em;
             margin: 0 0 .9rem; color: var(--muted); }
        section.shared h2 { color: var(--shared); }
        section.isolated h2 { color: var(--accent); }
        dl { margin: 0; }
        dt { font-size: .78rem; color: var(--muted); margin-top: .8rem; }
        dt:first-child { margin-top: 0; }
        dd { margin: .15rem 0 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
             font-size: .86rem; word-break: break-all; }
        footer { margin-top: 2rem; color: var(--muted); font-size: .82rem; }
    </style>
</head>
<body>
<div class="wrap">
    <h1>Checkout <code>{{ $checkout }}</code></h1>
    <p class="lede">
        Open this page on the main checkout and on a worktree at the same time.
        The <strong>shared</strong> values are identical — one Postgres, one Redis, one Mailpit.
        The <strong>isolated</strong> values differ — each checkout keeps its own data.
    </p>

    <div class="grid">
        <section>
            <h2>This checkout</h2>
            <dl>
                @foreach ($identity as $label => $value)
                    <dt>{{ $label }}</dt><dd>{{ $value }}</dd>
                @endforeach
            </dl>
        </section>

        <section class="shared">
            <h2>Shared with every checkout</h2>
            <dl>
                @foreach ($shared as $label => $value)
                    <dt>{{ $label }}</dt><dd>{{ $value }}</dd>
                @endforeach
            </dl>
        </section>

        <section class="isolated">
            <h2>Isolated to this checkout</h2>
            <dl>
                @foreach ($isolated as $label => $value)
                    <dt>{{ $label }}</dt><dd>{{ $value }}</dd>
                @endforeach
            </dl>
        </section>
    </div>

    <footer>Laravel {{ app()->version() }} · PHP {{ PHP_VERSION }} · environment {{ app()->environment() }}</footer>
</div>
</body>
</html>

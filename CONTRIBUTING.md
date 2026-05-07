# Contributing

Thanks for improving Agent Monitor. Keep changes small, local-first, and easy to verify.

## Development

```bash
npm install
cp .env.example .env
npm run build:web
npm run start
```

For frontend iteration:

```bash
npm run dev:web
```

Before sending a change:

```bash
npm run check
npm run build:web
npm run check:rust
```

For Apple app changes:

```bash
npm run build:mac
npm run build:ios
```

## Design Constraints

- Keep the service usable on a phone first.
- Avoid account systems, databases, and hosted dependencies unless the product direction changes.
- Prefer tmux primitives over custom process management.
- Treat terminal input as sensitive. Do not add logging for user-entered text.
- Do not make token auth mandatory for trusted LAN/Tailscale use, but keep the optional token path working.
- Keep `apps/apple` as one XcodeGen project with separate macOS and iOS targets unless there is a strong reason to split it.

## Reporting Issues

Include:

- macOS version and shell
- tmux version
- whether you use LAN, Tailscale, or a tunnel
- service URL and port, without tokens
- the output of `tmux ls`
- relevant service logs

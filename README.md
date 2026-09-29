# dotenv-lint

Lint `.env` files for the mistakes that cause 2 a.m. incidents: duplicate
keys, broken lines, empty secrets and unquoted spaces. One POSIX shell
script, no dependencies.

## Checks

| Check | Level |
|---|---|
| Duplicate KEY definitions | error |
| Line is not `KEY=VALUE` (comments/blanks/`export` are fine) | error |
| Key is not `UPPER_SNAKE_CASE` | warning |
| Empty value for `*PASSWORD* / *SECRET* / *TOKEN* / *API_KEY* / *_KEY` | error |
| Unquoted value containing spaces | error |
| Key present in a reference `.env.example` but missing (with `-e`) | error |

Inline comments (`KEY=value  # note`) are supported for unquoted values; `#`
inside a value without preceding whitespace is kept.

## Usage

```console
$ dotenv-lint .env
.env:4: error: duplicate key 'DB_HOST'
.env:7: error: secret key 'API_TOKEN' has an empty value
dotenv-lint: 2 error(s), 0 warning(s)

$ dotenv-lint -e .env.example .env
$ dotenv-lint --selftest
selftest: 15 passed, 0 failed
```

Use it in CI to keep environment files honest:

```sh
dotenv-lint .env.production || exit 1
```

## Requirements

POSIX shell (bash 3.2+ works), sed, grep, mktemp.

## Testing

```console
$ ./dotenv-lint.sh --selftest
```

Covers every check type, exit codes and the clean-file path.

## License

MIT

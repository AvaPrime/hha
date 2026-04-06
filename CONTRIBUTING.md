# Contributing

Thanks for contributing.

## Development Setup

Prerequisites:

- Python 3.13+

Create and activate a virtual environment:

```bash
python -m venv .venv
```

Windows PowerShell:

```bash
.\.venv\Scripts\Activate.ps1
```

Install dependencies:

```bash
python -m pip install -r requirements.txt
```

Run tests:

```bash
python -m unittest discover -s health_adapter/tests -p "test_*.py" -v
```

## Code Style

- Keep changes small and reviewable.
- Prefer explicit names over abbreviations.
- Keep modules focused (diagnosis vs planning vs execution vs persistence).
- Avoid committing generated files or caches (`__pycache__`, `.mypy_cache`, `.venv`, `.env`).

## Pull Request Process

1. Create a topic branch from `main`.
2. Ensure tests pass.
3. Update documentation when changing public behavior or schemas.
4. Submit a PR with:
   - clear summary of intent
   - links to updated spec sections if applicable
   - notes on backward compatibility impact

## Schema Changes

- Prefer additive schema changes.
- For PostgreSQL enums, ensure migrations handle existing deployments (use `ALTER TYPE ... ADD VALUE IF NOT EXISTS`).
- Update the unified schema pack and the Supabase migrations together.


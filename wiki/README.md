# Wiki Directory

This directory contains the source files for the GitHub wiki at:
**https://github.com/Skeyelab/coinbase_futures_bot/wiki**

## Automated Publishing

Changes to files in this `wiki/` directory are automatically published to the GitHub wiki via GitHub Actions workflow (`.github/workflows/sync-wiki.yml`).

### How it works:
1. **Edit files** in this `wiki/` directory
2. **Commit and push** to the `main` branch
3. **GitHub Actions** automatically syncs the content to the wiki repository
4. **Wiki is updated** within minutes

### Manual Trigger:
You can also manually trigger the sync from the GitHub Actions tab:
- Go to: https://github.com/Skeyelab/coinbase_futures_bot/actions
- Select "Sync Documentation to Wiki"
- Click "Run workflow"

## File Structure

- `Home.md` - Main wiki landing page (required)
- `*.md` - Individual wiki pages
- All files are copied directly to the wiki repository

## Important Notes

1. **Home.md is required** - GitHub wikis need a Home.md file as the main page
2. **File names become URLs** - `API-Reference.md` becomes `/wiki/API-Reference`
3. **Links use wiki syntax** - `[Page Title](Page-Name)` not `[Page Title](Page-Name.md)`
4. **Images** - Store in the wiki repo or use external URLs

## Development Workflow

```bash
# Edit wiki files locally
vim wiki/Architecture.md

# Commit and push
git add wiki/
git commit -m "docs: update architecture documentation"
git push origin main

# GitHub Actions will automatically sync to wiki
```

## Wiki vs Docs

- **`wiki/`** - User-facing documentation, formatted for GitHub wiki
- **`docs/`** - Developer documentation, technical specs, raw documentation

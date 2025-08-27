# Branch Protection Setup Instructions for FUT-1

This document provides step-by-step instructions to enable branch protection on the `main` branch for the `Skeyelab/coinbase_futures_bot` repository.

## Required Settings Summary

Based on Linear issue FUT-1, the following settings need to be configured:

### Pull Request Requirements
- ✅ Require a pull request before merging
- ✅ Require approvals: **1**
- ✅ Dismiss stale reviews: **enabled**
- ✅ Require review from Code Owners: **enabled**

### Status Check Requirements
- ✅ Require status checks to pass before merging
- ✅ Status checks: **lint**, **security**, **test** (from CI workflow)
- ✅ Require branches to be up to date before merging: **enabled**

### Additional Protections
- ✅ Require signed commits: **enabled** (optional, recommended)
- ✅ Include administrators: **enabled**
- ✅ Restrict who can push to matching branches: **only via PR** (no direct pushes)

## Manual Setup Instructions

### Step 1: Navigate to Branch Protection Settings
1. Go to the repository: https://github.com/Skeyelab/coinbase_futures_bot
2. Click on **Settings** tab
3. Click on **Branches** in the left sidebar
4. Click **Add rule** next to "Branch protection rules"

### Step 2: Configure Basic Settings
1. **Branch name pattern**: `main`
2. Check ✅ **Restrict pushes that create files larger than 100 MB**

### Step 3: Configure Pull Request Settings
1. Check ✅ **Require a pull request before merging**
2. Under "Required approvals":
   - Set to **1**
   - Check ✅ **Dismiss stale PR reviews when new commits are pushed**
   - Check ✅ **Require review from CODEOWNERS**

### Step 4: Configure Status Check Settings
1. Check ✅ **Require status checks to pass before merging**
2. Check ✅ **Require branches to be up to date before merging**
3. In the "Status checks that are required" search box, add:
   - `lint` (StandardRB linting)
   - `security` (Brakeman security scan)
   - `test` (Rails test suite)

   **Note**: These status checks will appear in the list after they run at least once in a PR.

### Step 5: Configure Additional Restrictions
1. Check ✅ **Require signed commits** (recommended for security)
2. Check ✅ **Include administrators** (applies rules to repo admins too)
3. Check ✅ **Restrict pushes that create files larger than 100 MB**

### Step 6: Save Configuration
1. Click **Create** to save the branch protection rule

## Verification

After setting up the branch protection, verify the configuration by:

1. Checking that the protection rule appears under "Branch protection rules"
2. Creating a test PR to ensure:
   - CI checks run automatically
   - Approval is required before merging
   - Direct pushes to main are blocked

## Current Repository Status

✅ **CI Workflow**: Already configured in `.github/workflows/ci.yml`
- `lint`: StandardRB linting
- `security`: Brakeman security scanning  
- `test`: Rails test suite with PostgreSQL

✅ **CODEOWNERS**: Already configured in `.github/CODEOWNERS`
- Default owner: `@Skeyelab`

## GitHub API Configuration (Alternative)

If you have admin access and prefer to use the GitHub API, here's the exact configuration:

```bash
curl -X PUT \
  -H "Authorization: token YOUR_ADMIN_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  -d '{
    "required_status_checks": {
      "strict": true,
      "contexts": ["lint", "security", "test"]
    },
    "enforce_admins": true,
    "required_pull_request_reviews": {
      "required_approving_review_count": 1,
      "dismiss_stale_reviews": true,
      "require_code_owner_reviews": true
    },
    "restrictions": null,
    "allow_force_pushes": false,
    "allow_deletions": false
  }' \
  "https://api.github.com/repos/Skeyelab/coinbase_futures_bot/branches/main/protection"
```

## Contact

Once the branch protection has been enabled, please comment on Linear issue FUT-1 to confirm completion.

---
*Generated for Linear issue FUT-1 on 2025-08-27*
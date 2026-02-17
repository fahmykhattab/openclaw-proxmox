# Issues Found & Fixes Needed

## Critical Issues:
1. ❌ openclaw user not being created during install
2. ❌ auth.token in config (invalid key)
3. ❌ server.js not being written to /opt/openclaw-webui/
4. ❌ Unicode emoji escapes in dashboard HTML
5. ❌ Docker permissions for openclaw user
6. ❌ Missing models array in Ollama provider config
7. ❌ openclaw service not being installed

## What Works:
- ✅ Script downloads and runs
- ✅ Container gets created
- ✅ Docker installs
- ✅ Nginx installs
- ✅ Dashboard structure created
- ✅ Ollama URL detection

## Root Causes:
- The install script seems to skip user creation step
- The base64 server.js decode isn't executing properly
- Config template has auth section that shouldn't exist
- Service installation might be conditional and failing

## Fixes to Apply:
1. Ensure openclaw user creation is mandatory and verified
2. Remove auth.token from all config templates
3. Fix base64 decode for server.js (ensure it writes properly)
4. Add post-install verification steps
5. Auto-run doctor --fix after install
6. Make Docker group membership part of user creation
7. Create required directories upfront

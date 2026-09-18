# udpte version-2

# ESS Face Deployment Manager

Automates installing the **ESS Face** app (frontend + FastAPI backend + Caddy reverse proxy) as Windows services via [Servy](https://github.com/servy-community/servy).

---

## 📋 Before you begin — config files

Edit these **before** your first deploy if your setup differs from the defaults.

### `deploy.config.json` — settings (ports, paths, repos)

### `deploy.secrets.json` — settings (credentials)

Created automatically on first run. Edit it to change:

> ⚠️ **Do not use ports** `80`, `443`, `8080`, `3000`, `8000`, `5000` — these are typically taken by other services (IIS, web servers, dev tools). Pick free ports instead. The Face defaults (`3110`, `8110`, `9110`, `2110`) are intentionally separate from the previous deployment ports.

| Field | Default | What it does | Can be changed? |
|---|---|---|---|
| `Environment` | `production` | Selects isolated install and service names | ✅ Use `production` or `development` |
| `FrontendRepo` | `Posuza/ESS-Face-Frontend` | Git repo for the frontend | ✅ Replace with your own repo URL |
| `FrontendBranch` | `main` | Frontend Git branch to deploy | ✅ Use `ver1` for development |
| `BackendRepo` | `Posuza/ESS-Face-Backend` | Git repo for the FastAPI backend | ✅ Replace with your own repo URL |
| `BackendBranch` | `main` | Backend Git branch to deploy | ✅ Use `ver1` for development |
| `FrontendPort` | `3110` | Port the frontend serves on | ✅ Change if needed |
| `BackendPort` | `8110` | Port the backend API runs on | ✅ Change if needed |
| `CaddyPort` | `9110` | Port the reverse proxy listens on | ✅ Change if needed |
| `CaddyAdminPort` | `2110` | Caddy admin API port | ✅ Change if needed |
| `ApiPrefix` | `/api/v1` | API path prefix | ✅ Any prefix starting with `/` (e.g. `/api`, `/v2`) |
| `FrontendPublicUrl` | `null` | Public URL used in backend-generated links such as password reset emails. Blank/null uses `http://localhost:<CaddyPort>` | ✅ Set your LAN/DNS URL if users open the app from another computer |
| `MediaStoragePath` | `null` | Persistent backend image storage. Blank/null uses `<drive>:\ESS\storage` and stores face images in `employee-faces\` | ✅ Set an absolute path, or a path relative to `<drive>:\ESS`. It can point to either a storage root or directly to an `employee-faces` folder |
| `InstallRoot` | *(set at startup)* | Derived from the selected drive and environment | ✅ `<drive>:\ESS\Ess_Face` for production, `<drive>:\ESS\Ess_Face_dev` for development |

Production services use the `ess-face-*` prefix. Development services use
`ess-face-dev-*`, allowing both environments to run on the same machine when
their configured ports are different.

Ready-to-use profiles are provided in `deploy.production.config.json` and
`deploy.development.config.json`. Copy the required profile over
`deploy.config.json` before running the deployment script.

### `deploy.secrets.json` — credentials (DB, SMTP)

Auto-gitignored. Copy `deploy.secrets.example.json` → `deploy.secrets.json` to pre-fill, or enter them when the script prompts you.

```json
{
  "db":   { "host": "localhost", "port": "3306", "name": "ess_face", "user": "root", "password": "..." },
  "smtp": { "host": "smtp.gmail.com", "port": "587", "user": "...", "pass": "...", "from": "..." }
}
```

> If you skip pre-filling, the script will ask for these interactively.

---

## 🚀 Step-by-step installation guide

### 1. Prepare credentials

Before running the script, make sure your DB and SMTP credentials are ready.
You can either:

- **Pre-fill** `deploy.secrets.json` with your real values (copy from `deploy.secrets.example.json`)
- **Or let the script prompt you** — it will ask for credentials at the start of the deployment

> If credentials are missing or still contain placeholders, the backend deployment stops so you can fill `deploy.secrets.json` first.

### 2. Run the script

Open **PowerShell as Administrator** and run:

```powershell
# Navigate to the folder first
cd C:\path\to\ess-face

# Run
.\deploy.ps1
```

If execution policy blocks it:

```powershell
powershell -ExecutionPolicy Bypass -File "filepath\deploy.ps1"
```

### 3. Set install location (first run only)

You'll be asked to pick a **drive** (e.g. `C:`, `D:`). The script creates an `ESS` folder there if needed, then creates the app folder inside it (`C:\ESS\Ess_Face`).

### 4. Use the main menu

```
 1) Check prerequisites
 2) Install components
 3) Uninstall components
 4) Service status / health check
 5) Start services
 6) Stop services
 7) Caddy network config
 8) Open logs folder
 Q) Quit
```

---

### 4. Install everything

Press **`2`** then **`A`** to install all components (or pick individually by number).

The script will:
1. Check prerequisites (Git, Node.js, Python) — installs missing ones
2. Ask for DB/SMTP credentials (if not pre-filled)
3. Install each component:
   - **Frontend** — clones repo, `npm install`, builds, registers as a Windows service
   - **Backend** — clones repo, cleans stale untracked files, creates venv, `pip install`, generates `.env`, creates persistent image storage, and registers the API service
   - **Caddy** — downloads Caddy, creates `Caddyfile`, registers as service

Backend face profile images are stored outside the cloned backend repo and outside `Ess_Face`, so they survive reinstalling or deleting app service folders. By default the folders are:

```text
C:\ESS\Ess_Face
C:\ESS\storage\employee-faces
```

The frontend does not read `C:\ESS\storage` directly. It requests images from the backend API (`/api/v1/faces/.../profile-image` and `/api/v1/admin/users/.../face-profile`), and the backend returns the JPEG from `MEDIA_STORAGE_PATH`. Caddy only needs the normal `/api/v1/* -> backend` route for images to show in the frontend.

Set `MediaStoragePath` in `deploy.config.json` if you want those images in another folder. Relative paths are resolved from `C:\ESS`. For example, both `D:\ESS\storage` and `D:\ESS\storage\employee-faces` are valid; the installer will create the needed folder if it does not exist.

Uninstall removes only the selected app services and, if you confirm file deletion, the app folders under `C:\ESS\Ess_Face`. It never deletes `C:\ESS\storage`.
4. Optionally start all services and verify health

---
## 🔧 Caddy network config (option 7)

Use **option 7** to manage which services Caddy proxies to:

```
 Caddy listener : 127.0.0.1:9110

 Available targets:
   (all targets already registered)

 Caddy routes:
   1) /*         → 127.0.0.1:3110  [Frontend]
   2) /api/v1/*  → 127.0.0.1:8110  [Backend]

 1) Add route to Caddy
 2) Remove route from Caddy
 3) Change Caddy listening port
 B) Back to main menu
```

- **Add route** — pick an available service (frontend, backend, or custom), specify a path prefix, confirm. Caddyfile regenerates and Caddy restarts.
- **Remove route** — pick a route by number, confirm removal.
- **Change port** — update the port Caddy listens on.

---

## 📖 Full menu reference

| Option | What it does |
|--------|-------------|
| **1** | Check & install prerequisites (Git, Node.js, Python) |
| **2** | Install components — pick **A** (all), **1** (Frontend), **2** (Backend), **3** (Caddy), or **B** (back) |
| **3** | Uninstall components — same submenu, with status indicators |
| **4** | Show service status table + run health checks |
| **5** | Start services — **A** (all), **1-3**, or **B** (back) |
| **6** | Stop services — same submenu |
| **7** | Caddy proxy config — add/remove routes, change port |
| **8** | Open logs folder in File Explorer |
| **Q** | Quit |

---

## 🤖 Headless / automated mode

```powershell
# Full deploy — no prompts
.\deploy.ps1 -Force

# Deploy only specific components
.\deploy.ps1 -Force -Components frontend,backend

# Preview only (dry run)
.\deploy.ps1 -DryRun

# Preview specific components
.\deploy.ps1 -DryRun -Components frontend,backend
```

> Make sure `deploy.config.json` and `deploy.secrets.json` exist and are configured before running headless.

---

## ❓ Troubleshooting

| Problem | Fix |
|---------|-----|
| **Script won't run** | Use `powershell -ExecutionPolicy Bypass -File .\deploy.ps1` |
| **Service won't uninstall** | Restart Windows, then re-run uninstall |
| **Port conflict** | Change Caddy port in option 7 (option 3) or edit `deploy.config.json` |
| **Frontend build fails** | Check `logs/frontend_build.log` in the install directory |
| **Backend won't start** | Check `logs/backend_pip.log` and verify `.env` has correct DB credentials |
| **Logs location** | `<InstallRoot>\logs\deploy-YYYYMMDD-HHmmss.log` |

---

## 📁 Files

| File | Purpose | Tracked in Git? |
|------|---------|:---:|
| `deploy.ps1` | Main deployment script | ✅ |
| `deploy.config.json` | Ports, paths, repos, routes | ✅ |
| `deploy.secrets.example.json` | Credentials template | ✅ |
| `deploy.secrets.json` | Your real DB/SMTP credentials | ❌ (gitignored) |

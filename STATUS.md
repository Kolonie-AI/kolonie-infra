# kolonie-infra — Status

## Aktueller Stand (26.07.2026, 11:15 MEZ)

**Deploy-Workflow funktioniert.** Traefik + PostgreSQL laufen auf der VPS.

```
kolonie-traefik    healthy   (v3.7, Reverse Proxy, Let's Encrypt via Cloudflare DNS Challenge)
kolonie-postgres   healthy   (PostgreSQL 16-alpine)
```

## Was gefixt wurde (26.07.2026)

### deploy.sh
- `docker compose pull "all"` schlug fehl weil "all" kein gueltiger Service-Name ist.
- Fix: bei `SERVICE=all` wird `docker compose pull` ohne Argument ausgefuehrt (nur non-profiled Services: traefik, postgres). Services mit `profiles: [full]` (backend, frontend, academy) werden einzeln deployed wenn ihre Images existieren.

### deploy.yml
- `VPS_USER` war auf `deploy` gesetzt, aber auf der VPS existiert nur `ubuntu`.
- Fix: `VPS_USER: ubuntu` (stimmt mit dem SSH-Key in GitHub Secrets ueberein).

### healthcheck.sh
- Urspruenglich curl gegen Domains (kolonie.ai, api.kolonie.ai, academy.kolonie.ai) - failt wenn DNS nicht zeigt.
- Fix: prueft jetzt direkt den Docker-Container-Status via `docker inspect`.

### traefik.yml
- Ping-Endpoint fehlte. Traefik Healthcheck braucht `ping` in den entryPoints.
- Fix: `ping` entryPoint auf Port 8080 hinzugefuegt, `ping.entryPoint: ping` in der Root-Config.

## Was noch fehlt

### Unmittelbar
- [ ] Cloudflare DNS Records: `kolonie.ai`, `api.kolonie.ai`, `academy.kolonie.ai` muessen auf die VPS-IP zeigen (derzeit nur via Cloudflare Proxy erreichbar).
- [ ] TLS-Zertifikat: Let's Encrypt DNS Challenge braucht funktionierende DNS Records. Aktuell: `acme.json` existiert, aber kein Zertifikat ausgestellt.

### Services
- [ ] Backend-Image (`ghcr.io/kolonie-ai/kolonie-backend:latest`) existiert nicht.
- [ ] Frontend-Image (`ghcr.io/kolonie-ai/kolonie-frontend:latest`) existiert nicht.
- [ ] Academy-Image (`ghcr.io/kolonie-ai/kolonie-academy:latest`) existiert nicht.
- [ ] Build-Workflows in den jeweiligen Repos fehlen noch.
- [ ] Ohne Images schlagen die `profiles: [full]` Services fehl - Traefik routed auf nicht erreichbare Container (502).

### Infrastruktur
- [ ] `/opt/kolonie/backups/` ist leer (kein Backup-Prozess ausser den Skripten).
- [ ] Kein automatisches DB-Backup (pg_dump Cron fehlt).
- [ ] Kein Log-Rotation fuer Container-Logs.
- [ ] Traefik Dashboard ist deaktiviert (`api.dashboard: false`).

## VPS-Zugang

- **Host:** <hosting-provider-redacted> VPS, Ubuntu 24.04
- **Login:** `ubuntu` via SSH-Key (Key liegt in GitHub Secrets als `VPS_SSH_KEY`)
- **Root-Zugang:** `root` wird von der VPS nicht akzeptiert ("Please login as ubuntu")
- **Docker:** v29.6.2, Compose v5.3.1
- **Deploy-Verzeichnis:** `/opt/kolonie/`
- **Repo:** Vollstaendig geklont, `git pull origin main` im Deploy-Workflow

## GitHub Actions

| Run | Status | Problem |
|-----|--------|---------|
| 30196085109 | **OK** | Manueller Trigger, alles gruen |
| 30195972332 | fail | Traefik unhealthy (alte Config ohne ping) |
| 30195914419 | fail | VPS_USER `deploy` existiert nicht |
| 30174432952 | fail | `no such service: all` |
| 30171884900 | fail | curl gegen Domains (DNS zeigt nicht) |

**Trigger:** Automatisch bei Push auf `main`, oder manuell via `workflow_dispatch`.
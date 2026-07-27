# kolonie-infra — Status

## Aktueller Stand (27.07.2026)

**DNS steht, Services fehlen.** Die drei Hosts liefern 502, weil noch kein
Anwendungs-Image gebaut ist. Traefik und PostgreSQL laufen.

Umbenannt am 27.07.2026 im Zuge der Repo-Konsolidierung:
`backend` → `api`, `academy` → `verifier-runner`, `frontend` → `website`.
`verifier-runner` hat bewusst keine Traefik-Route.

## Vorheriger Stand (26.07.2026, 11:15 MEZ)

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
- [x] Cloudflare DNS Records gesetzt: `kolonie.ai`, `www`, `api`, `academy` zeigen proxied auf den Origin (Stand 27.07.2026).
- [x] Namecheap-Parking entfernt: der Apex hatte einen zweiten A-Record auf eine Parking-Seite, dadurch ging rund die Haelfte aller Requests auf die falsche Seite. Ausserdem zeigte `www` per CNAME auf `parkingpage.namecheap.com`, jetzt auf den Apex.
- [ ] Cloudflare SSL-Modus auf **Full (strict)** pruefen. Der DNS-Token darf Zone-Settings nicht lesen (Fehler 9109), das geht nur im Dashboard.
- [ ] Origin-Zertifikat: Edge-TLS laeuft ueber Cloudflare Universal SSL (Google Trust Services). Traefik hat noch kein eigenes Let's-Encrypt-Zertifikat ausgestellt — faellt erst auf, wenn der SSL-Modus auf Full (strict) steht.

### Services
- [x] `ghcr.io/kolonie-ai/kolonie-api:latest` gebaut (27.07.2026).
- [x] `ghcr.io/kolonie-ai/kolonie-verifier-runner:latest` gebaut (27.07.2026).
- [x] Path-gefilterte Build-Workflows in `kolonie-platform` laufen gruen.
- [ ] `ghcr.io/kolonie-ai/kolonie-website:latest` existiert nicht — Repo noch nicht angelegt.
- [ ] **GHCR-Login auf der VPS fehlt.** Beide Images sind privat, weil das Repo
      privat ist. `docker compose --profile full pull` schlaegt ohne
      Authentifizierung mit `denied` fehl. Noetig: ein PAT mit `read:packages`
      als GitHub-Actions-Secret, und im Deploy-Workflow ein
      `docker login ghcr.io` vor dem Pull. Alternativ die beiden Pakete auf
      public stellen — das geht unabhaengig von der Repo-Sichtbarkeit.
- [ ] Ohne laufende Container antwortet Traefik mit 502 — aktueller Zustand auf allen drei Hosts.

### Infrastruktur
- [ ] `/opt/kolonie/backups/` ist leer (kein Backup-Prozess ausser den Skripten).
- [ ] Kein automatisches DB-Backup (pg_dump Cron fehlt).
- [ ] Kein Log-Rotation fuer Container-Logs.
- [ ] Traefik Dashboard ist deaktiviert (`api.dashboard: false`).

## VPS-Zugang

- **Host:** Cloud VPS, EU-Region, Ubuntu 24.04 (Provider und IP stehen bewusst
  in keinem Repo — siehe ARCHITECTURE.md, Security)
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
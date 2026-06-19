# Infra Servicios

Infraestructura compartida para los servicios de Traficaño: un solo droplet de DigitalOcean con un Postgres compartido, donde corren **Cotizador (autocotizador)**, **brica-stockintermedio** y **sumin-stockintermedio**.

## Arquitectura

- **Un solo Postgres** (`postgres:18-alpine`) para los 3 servicios, no uno por app.
- **Aislamiento por base, no por servidor**: cada servicio tiene su propio usuario de Postgres con permiso `CREATEDB`, y crea su propia base la primera vez que arranca (no hace falta crearla a mano).
- **Red de Docker compartida** (`infra_shared`): este repo la crea; cada servicio se conecta a ella desde su propio `docker-compose.yml` (declarándola como `external: true`) para poder resolver el Postgres por nombre de servicio (`postgres`), sin exponer nada a internet.
- Cada app es su propio repo, con su propio CI/CD que publica una imagen a GHCR. Este repo (`Infra Servicios`) solo orquesta lo compartido (Postgres + red + el droplet en sí vía Terraform). El día a día de cada app vive en su propio repo.

```
                     ┌─────────────────────────────┐
                     │   droplet (DigitalOcean)    │
                     │                              │
  GHCR ──pull──▶ ┌───┤ autocotizador (app)         │
                 │   ├──────────────────────────────┤
  GHCR ──pull──▶ ┌───┤ brica-stockintermedio (app)  │
                 │   ├──────────────────────────────┤
  GHCR ──pull──▶ ┌───┤ sumin-stockintermedio (app)  │
                 │   ├──────────────────────────────┤
                 └───┤ postgres (este repo)         │
                     │   - db autocotizador          │
                     │   - db brica_stockintermedio  │
                     │   - db sumin_stockintermedio  │
                     └─────────────────────────────┘
                  todos conectados a la red infra_shared
```

## Usuarios de Postgres

Se crean solos al primer arranque (`init-db/01-create-users.sh`), cada uno con `CREATEDB`:

| Usuario | Para |
|---|---|
| `autocotizador` | Cotizador |
| `brica_stockintermedio` | Stock Intermedio - Brica |
| `sumin_stockintermedio` | Stock Intermedio - Sumin |

Las contraseñas están en `.env` (no versionado). Ver `.env.example` para la lista completa de variables.

## Cómo se conecta cada app

En el `docker-compose.yml` de **cada servicio** (no de este repo):

```yaml
services:
  app:
    image: ghcr.io/<org>/<servicio>:latest
    environment:
      DATABASE_URL: postgresql://<usuario>:<password>@postgres:5432/<usuario>
    networks:
      - infra_shared

networks:
  infra_shared:
    name: infra_shared
    external: true
```

El host es `postgres` (el nombre del servicio acá), no una IP — Docker lo resuelve solo porque ambos compose están en la misma red.

## Levantar el Postgres compartido

```bash
docker compose up -d
```

Primera vez: crea la red `infra_shared`, el volumen `pg_data`, y corre `init-db/01-create-users.sh` (solo corre una vez, cuando el volumen está vacío).

## Restaurar un backup en la base de un servicio

Mismo procedimiento para cualquiera de los 3:

```bash
# 1. Parar la app del servicio en cuestión (no el Postgres)
# 2. Vaciar su base (si no está vacía, pg_restore tira "already exists" en todo)
docker compose exec postgres psql -U admin -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='<base>' AND pid <> pg_backend_pid();" \
  -c "DROP DATABASE IF EXISTS <base>;" \
  -c "CREATE DATABASE <base> OWNER <usuario>;"

# 3. Copiar el dump al contenedor y restaurar como el usuario del servicio
docker compose cp backup.dump postgres:/tmp/backup.dump
docker compose exec -e PGPASSWORD=<password> postgres \
  pg_restore -U <usuario> -d <base> --no-owner --no-privileges --exclude-schema=_system /tmp/backup.dump

# 4. Levantar la app de nuevo
```

`--no-owner --no-privileges` evita errores con roles que no existen acá (si el backup viene de Neon/Replit, trae roles como `neondb_owner`). `--exclude-schema=_system` saltea una tabla interna de Replit que no es parte de los datos reales.

**Importante:** si el dump fue generado con un `pg_dump` más nuevo que la versión de Postgres de este servidor, `pg_restore` tira `unsupported version in file header`. Solución: correr el restore con un cliente de Postgres más nuevo apuntando a este servidor (ver historial del proyecto Cotizador para el procedimiento exacto con un contenedor temporal de `postgres:18-alpine`).

## Terraform (provisión del droplet)

En `terraform/`. Crea el droplet (con Docker + Docker Compose instalados solos vía `user_data`, swap de 2GB configurado), un firewall (22/80/443 abiertos) y sube la SSH key.

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

Requiere `terraform/terraform.tfvars` (no versionado) con el API token de DigitalOcean — ver `terraform.tfvars.example`.

## Apps de cada servicio (`autocotizador/`, `brica-stockintermedio/`, `sumin-stockintermedio/`)

Cada carpeta tiene su propio `docker-compose.yml` + `.env`, todas conectadas a `infra_shared` y con su propio puerto publicado para no chocar entre sí:

| Carpeta | Puerto | Imagen |
|---|---|---|
| `autocotizador/` | `5000` | `ghcr.io/<org>/cotizador:latest` |
| `brica-stockintermedio/` | `8080` | `ghcr.io/<org>/stock-intermedio:latest` |
| `sumin-stockintermedio/` | `8081` | `ghcr.io/<org>/stock-intermedio:latest` |

`brica-stockintermedio` y `sumin-stockintermedio` además tienen su propio volumen de uploads, aislado por nombre de carpeta (`<carpeta>_uploads_data`). Antes de poder hacer `docker compose pull` en cualquiera, hay que loguearse una vez a GHCR (los packages son privados):

```bash
docker login ghcr.io -u <usuario-github> -p <personal-access-token-con-scope-read:packages>
```

## Dominios (Caddy)

Dominio: `traficano.com`, DNS gestionado en Hostgator. Reverse proxy con HTTPS automático vía `Caddyfile` (servicio `caddy` en el `docker-compose.yml` raíz, puertos 80/443):

| Subdominio | Servicio |
|---|---|
| `clientes.traficano.com` | `autocotizador-app:5000` |
| `brica.traficano.com` | `brica-stockintermedio-app:8080` |
| `sumin.traficano.com` | `sumin-stockintermedio-app:8080` |

Caddy obtiene los certificados de Let's Encrypt solo, la primera vez que alguien pega contra el dominio — no hace falta configurar nada más, siempre que el DNS ya apunte al droplet.

**El DNS sigue en Hostgator a propósito** (no se migró a DigitalOcean) para no arriesgar los registros de email u otros que ya tenga el dominio. Una vez que exista el droplet, agregar en Hostgator 3 registros **A**, los 3 apuntando a la IP del droplet:
- `clientes.traficano.com`
- `brica.traficano.com`
- `sumin.traficano.com`

## Pendiente

- [ ] `terraform apply` real (por ahora solo se validó el `plan`).
- [ ] Agregar los 3 registros A en Hostgator apuntando a la IP del droplet (recién se puede después del `apply`).
- [ ] Clonar este repo + los de cada servicio en el droplet una vez creado.
- [ ] `docker login ghcr.io` en el droplet (o hacer los packages públicos) para poder pullear las imágenes.
- [ ] Restaurar los backups reales de cada servicio en el droplet.
- [ ] Definir cómo se actualiza el droplet cuando el CI publica una imagen nueva (SSH manual, Watchtower, o un step de CI que se conecte).

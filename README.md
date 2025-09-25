# MarzGuard

MarzGuard keeps Marzban and its backing database running smoothly by watching the containers that power them, enforcing resource policies, and reacting before outages appear. It discovers containers automatically, tracks CPU and memory over sliding windows, and applies limits or restarts with guard rails. Everything ships in Bash so it installs quickly on Debian, Ubuntu, RHEL, CentOS, Rocky, and Alma systems.

## Features
- **Auto-discovery** of Marzban app and database containers using names, images, and labels with fully configurable keywords.
- **Sliding-window monitoring** for CPU and memory with adjustable intervals, window sizes, breach thresholds, and cooldown timers.
- **Action engine** that can apply CPU or memory limits, restart individual containers, and optionally restart the Docker daemon when severe conditions persist.
- **Health insights** including Docker health checks, restart counts, OOM events, disk capacity, daemon reachability, and Marzban UI/API connectivity.
- **Mock/test mode** that simulates containers and metrics so CI and operators can validate behaviour without Docker.
- **Polished CLI** (`MarzGuard`) for status, diagnostics, manual control, config editing, log viewing, and safe runtime operations.
- **Systemd service** with continuous monitoring, clean reload handling, journald integration, and log output to `/var/log/marzguard.log`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/YrustPd/MarzGuard/main/install.sh | bash
```

The installer will:
1. Verify root access and detect your package manager.
2. Install prerequisites and Docker if missing (falling back to manual instructions on failure).
3. Deploy the CLI to `/usr/local/bin/MarzGuard`, core library to `/usr/local/lib/marzguard`, the default config to `/etc/marzguard.conf`, the service unit to `/lib/systemd/system/MarzGuard.service`, and logrotate policy to `/etc/logrotate.d/marzguard`.
4. Enable and start the `MarzGuard` systemd service.
5. Print next steps for running a self-test, checking status, and reviewing logs.

## Quick Start

```bash
MarzGuard status
MarzGuard self-test
MarzGuard restart --app
MarzGuard limit cpu 1.5 --db
```

- `MarzGuard status` shows the service state, detected containers, recent actions, and threshold configuration.
- `MarzGuard self-test` runs the monitoring pipeline in mock mode to validate detection, sampling, and action logging.
- `MarzGuard restart --app` safely restarts only the application role containers while respecting cooldown rules.
- `MarzGuard limit cpu 1.5 --db` applies a CPU quota to the database role containers when manual throttling is required.

## Configuration

All tunables live in `/etc/marzguard.conf`. Each setting has inline documentation and sane defaults. Use `MarzGuard config` or `MarzGuard config --edit` to review and update the file quickly. Highlights include:

- **Discovery**: `MG_CONTAINER_FILTER_KEYWORDS`, `MG_APP_ROLE_KEYWORDS`, `MG_DB_ROLE_KEYWORDS`.
- **Sampling**: `MG_SAMPLE_INTERVAL`, `MG_WINDOW_SIZE`, `MG_MIN_BREACHES`.
- **Thresholds**: `MG_CPU_LIMIT_PERCENT`, `MG_MEM_LIMIT_PERCENT`, `MG_COOLDOWN_SECONDS`.
- **Actions**: `MG_AUTO_LIMIT_CPU`, `MG_CPU_LIMIT_CPUS`, `MG_AUTO_LIMIT_MEM`, `MG_MEM_LIMIT_BYTES`, `MG_AUTO_RESTART`, `MG_ALLOW_DOCKER_RESTART`.
- **Checks**: `MG_ENABLE_HEALTH_CHECK`, `MG_ENABLE_RESTART_COUNT_CHECK`, `MG_ENABLE_DISK_CHECK`, `MG_ENABLE_NETWORK_CHECK`.
- **Runtime paths**: `MG_RUNTIME_DIR`, `MG_STATE_DIR`, `MG_LOG_FILE`.
- **Mock mode**: toggle with `MG_MOCK_MODE=1` or `export MARZGUARD_MOCK=1` for ad-hoc runs.

Editing the config followed by `MarzGuard reload` (or `systemctl kill -s HUP MarzGuard`) picks up changes without a full restart.

## Logs

```bash
journalctl -u MarzGuard -f
```

Follow the service logs via journald; add `-n 100` to review a larger backlog or pipe through additional tooling if needed.

## Reload Configuration

```bash
sudo systemctl reload MarzGuard
```

Reload after editing `/etc/marzguard.conf` to apply new thresholds, detection filters, or toggles without a full restart.

## CLI Reference

`MarzGuard` offers a cohesive command set:

- `status` – service state, detected containers, current CPU/MEM figures, and recent actions.
- `print-detected` – raw container mapping (`ID|name|role`) after applying filters.
- `self-test` – runs the core monitor in mock mode for a few seconds; exits 0 on success.
- `doctor` – validates prerequisites (utilities, runtime availability, service state).
- `logs [-f]` – tails journald or the log file.
- `config [--edit]` – prints the current config or opens it in `$EDITOR`.
- `limit cpu <cpus> [--app|--db|--both]` – applies a CPU quota via `docker update --cpus`.
- `limit mem <size> [--app|--db|--both]` – applies a memory limit (`512MiB`, `2G`, etc.).
- `restart [--app|--db|--both]` – restarts matching containers with cooldown awareness.
- `restart-docker` – restarts Docker/Podman if enabled by config and confirmed interactively.
- `reload` – signals the service to reload configuration (falls back to local reload).
- `version` – prints the MarzGuard version.

Example workflows:

```bash
# Cap the app container at 1.5 CPUs during a spike
MarzGuard limit cpu 1.5 --app

# Apply a 2GiB hard limit to both app and database
MarzGuard limit mem 2GiB --both

# Restart only the database container after maintenance
MarzGuard restart --db

# Force a rediscovery and run mock sampling for diagnostics
MARZGUARD_MOCK=1 MarzGuard self-test
```

## Safety Notes & Troubleshooting

- Automated restarts and Docker daemon restarts are governed by explicit config flags; defaults are conservative.
- Container actions respect per-container cooldowns (`MG_COOLDOWN_SECONDS`) to avoid flapping.
- Disk and network warnings surface in both the log file and `MarzGuard status` output.
- If Docker installation via the installer fails (for air-gapped hosts, custom repos, etc.), follow the official Docker documentation and re-run the installer to lay down MarzGuard’s files.
- Run `MARZGUARD_MOCK=1 MarzGuard status` to fully exercise discovery and monitoring without Docker.

## Uninstall

```bash
sudo ./uninstall.sh
```

The uninstaller stops and disables the service, removes binaries and the unit file, and offers to delete configuration, logs, and runtime directories.

## License

MarzGuard is released under the [GNU Affero General Public License v3.0](LICENSE).

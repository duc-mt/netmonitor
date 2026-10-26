# LibreNMS on Docker (Windows, macOS, Linux)

[LibreNMS](https://www.librenms.org/) network monitoring, packaged as a Docker Compose project that
runs the same way on **Windows**, **macOS** (Intel and Apple Silicon) and **Linux**.

What you get:

- the official LibreNMS image, MariaDB, Redis and the dispatcher that actually runs the pollers
- one setup script per platform that generates all secrets (nothing is hard-coded, nothing secret is committed)
- backup and restore scripts for every platform, and one launcher (`./run` / `scripts/run.bat` / `scripts/run.ps1`) for the everyday commands
- optional syslog and SNMP trap receivers, an optional outbound mail relay, optional ntopng traffic analytics (Linux hosts), and an optional NetFlow/sFlow collector (NfSen) that feeds a
  Netflow tab in LibreNMS
- CI that tests the scripts on Linux, macOS and Windows, and runs the full stack with a backup/restore cycle on Linux

Based on the official example in [librenms/docker](https://github.com/librenms/docker/tree/master/examples/compose).

## Requirements

| Platform | Install |
|---|---|
| Windows 10/11 | [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/) with the WSL 2 backend (the default). Windows PowerShell 5.1 or PowerShell 7. |
| macOS | [Docker Desktop](https://docs.docker.com/desktop/setup/install/mac-install/). Apple Silicon runs natively: the images are published for `amd64`, `arm64` and `arm/v7`. |
| Linux | Docker Engine with the Compose plugin ([instructions](https://docs.docker.com/engine/install/)). |

You need Docker Compose **v2** (`docker compose version` must work) and about 4 GB of RAM for Docker.
On Windows and macOS, Docker Desktop must be running.

## Quick start

```bash
git clone <your-repo-url> librenms-docker
cd librenms-docker
```

**Linux / macOS**

```bash
bash scripts/setup.sh
```

**Windows (PowerShell)**

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
```

The script creates `.env` with a random database password and SNMP community, detects your timezone,
pulls the images and starts everything. The **first start takes several minutes** (image download and
database migrations). When it finishes it prints the address, normally <http://localhost:8000>.

1. Open the address. The first visit asks you to **create the admin account**.
2. Add a device: *Devices > Add Device*. Prefer **SNMPv3** (authPriv) over v2c where the device supports it.
3. For discovering a whole network, follow the [Auto-Discovery docs](https://docs.librenms.org/Extensions/Auto-Discovery/).

Running the script again is safe: an existing `.env` is kept, and so are its secrets.

## Everyday use

One launcher wraps the common tasks, with the same verbs on every platform:

```bash
./run up                    # start the stack              (Windows: .\scripts\run.ps1 up or scripts\run.bat up)
./run down                  # stop it, the data is kept
./run restart [service]     # restart everything, or one service
./run logs [service]        # follow the logs (Ctrl-C to stop)
./run status                # show the containers
./run backup [--keep 7]     # Windows: .\scripts\run.ps1 backup -Keep 7
./run restore latest        # Windows: .\scripts\run.ps1 restore latest -Yes
./run validate              # LibreNMS' own self-check (validate.php)
./run configure             # apply the settings in .env to LibreNMS; safe to repeat (--dry-run: only show)
./run add-device <host>     # add a device (e.g. ./run add-device 192.168.1.1 -v 2c -c public)
./run scan <subnet>         # auto-discover subnet devices via SNMP (e.g. ./run scan 192.168.1.0/24)
./run update                # back up, pull newer images, restart, self-check (--no-backup skips the backup)
./run doctor [--fix]        # check setup: Docker, .env, memory (--fix repairs .env permissions)
```

It works from any directory (`./run up`). On Windows, use `scripts\run.bat up` (CMD) or `.\scripts\run.ps1 up` (PowerShell). If scripts are blocked, use
`powershell -ExecutionPolicy Bypass -File scripts\run.ps1 up`. `down` never deletes the data volumes.

The plain Compose commands work everywhere too:

```bash
docker compose up -d --wait          # start
docker compose down                  # stop (data is kept)
docker compose ps                    # status
docker compose logs -f librenms      # follow the web log
docker compose pull && docker compose up -d --wait     # update to the newest images (no backup: prefer ./run update)
```

LibreNMS command line and self-check:

```bash
docker compose exec --user librenms librenms lnms          # list commands
docker compose exec --user librenms -w /opt/librenms librenms php validate.php
```

`validate.php` may report warnings that do not apply to Docker (updates happen by pulling a new image).

**When something is wrong, start with `./run doctor`** (Windows: `.\scripts\run.ps1 doctor`). It needs no running stack and
prints `ok`, `info`, `WARN` and `ERROR` lines; it exits 1 if there is any `ERROR`. It checks that Docker and Compose work,
that the secrets in `.env` are set (and, on Linux and macOS, that `.env` is private), that the enabled profiles are
complete (the mail relay has an `SMTP_HOST`, the ntopng interface exists), that every `NFSEN_SOURCES` entry is valid
(a name NfSen accepts, a port inside the published range, one port per device), that `MARIADB_BUFFER_POOL_SIZE` fits in
the memory Docker has, which web UIs listen on every network, and whether the services are running. It does not check
whether host ports are free.

**Updating.** `./run update` (Windows: `.\scripts\run.ps1 update`) lists the images in use and saves that list to
`backups/update-<time>.txt`, backs up, pulls newer images (images you built yourself are skipped), restarts, and runs
the self-check. If the stack does not become healthy it says so and stops; to go back, put the previous tags from the
saved list into `.env`, run `./run up`, and, if the database was upgraded in between, restore the backup too
(`./run restore latest`). A failing self-check is only reported, never rolled back. Read the LibreNMS release notes
before upgrading across several versions.

**Pinning versions.** `LIBRENMS_VERSION=latest` follows upstream. For reproducible deployments set a release tag in
`.env` and update deliberately with `./run update`. The LibreNMS Docker project numbers its releases like `26.8.2-r1`
([releases](https://github.com/librenms/docker/releases)), but the [Docker Hub tag list](https://hub.docker.com/r/librenms/librenms/tags)
is the authority on the exact tag names, so check it first: a tag that does not exist makes the pull fail. The same
variables exist for the other images (`MARIADB_VERSION`, `REDIS_VERSION`, `MSMTPD_VERSION`, `NFSEN_VERSION`,
`NTOPNG_VERSION`). Dependabot cannot keep these current, because the tags live in `.env` variables and not in the
`image:` lines; the LibreNMS Docker project points to Diun (Docker Image Update Notifier) for new-image notifications.

## Backup and restore

```bash
bash scripts/backup.sh                  # Linux / macOS
scripts\backup.ps1                   # Windows
```

Each backup is two files in `./backups`: `librenms-<timestamp>-db.sql.gz` (database) and
`librenms-<timestamp>-data.tgz` (RRD graphs, config, plugins; logs and cache are left out, LibreNMS rebuilds them). Add `--keep 7` (`-Keep 7` on Windows) to
retain only the newest 7 sets. The dispatcher is paused while the backup runs and is always restarted
afterwards, so graphs get a short gap. Run it from cron or Task Scheduler for regular backups.

```bash
bash scripts/restore.sh latest          # newest backup (asks for confirmation)
bash scripts/restore.sh 20260101-120000 --yes
scripts\restore.ps1 latest
```

Name the backup as `latest`, `20260101-120000`, `librenms-20260101-120000`, or by a path or file name from
`./backups` (`backups/librenms-20260101-120000-db.sql.gz`), so shell tab completion just works.

A restore **replaces** the current database and data. Both archives are verified *before* anything is
deleted, so a corrupt backup cannot destroy a working system. Backups contain device credentials:
treat `./backups` as secret (it is git-ignored).

### Scheduled and off-site backups

A backup is only useful if it runs by itself and does not live only on the machine it protects. The database dump holds
the credentials LibreNMS stores for your devices, so treat the files in `./backups` as secrets.

Linux, with cron (`crontab -e`; the project folder is the one you cloned into):

```
30 2 * * * cd /opt/librenms-docker && ./run backup --keep 14 >> backups/cron.log 2>&1
```

Linux, with a systemd timer (`systemctl enable --now librenms-backup.timer`):

```ini
# /etc/systemd/system/librenms-backup.service
[Unit]
Description=LibreNMS backup
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=/opt/librenms-docker
ExecStart=/opt/librenms-docker/run backup --keep 14

# /etc/systemd/system/librenms-backup.timer
[Unit]
Description=Daily LibreNMS backup

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true

[Install]
WantedBy=timers.target
```

Windows (Docker Desktop must be running at that time):

```
schtasks /Create /TN "LibreNMS backup" /SC DAILY /ST 02:30 /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\librenms-docker\scripts\run.ps1 backup -Keep 14"
```

macOS: cron has a minimal `PATH`, so add `PATH=/usr/local/bin:/usr/bin:/bin` as the first line of the crontab (Docker
Desktop's command line tools live in `/usr/local/bin`), or use launchd.

Copy the finished backups to another machine, for example with `rsync -a backups/ backup-host:/srv/librenms-backups/` or
`rclone copy backups remote:librenms-backups`. To encrypt them first, [age](https://github.com/FiloSottile/age) does it in
one command per file: `age -r <public-key> -o librenms-<timestamp>-db.sql.gz.age librenms-<timestamp>-db.sql.gz`. These are
examples to adapt, not part of the scripts, and they have not been run as part of this project.

## Database access and recovery

A SQL shell as the application user (its password is `MYSQL_PASSWORD` in `.env`):

```bash
docker compose exec db mariadb -u librenms -p
```

`-u` takes your `MYSQL_USER` if you changed it, and `-p` prompts for the password. That user owns the LibreNMS
database, which is all LibreNMS needs, and nothing in this project uses the MariaDB **root** account. Root has a random
password that was printed once, in the log of the very first start, and logs are rotated away over time. If you ever
need root, or lost the application password, restart MariaDB with the privilege checks off and reset it:

1. `docker compose stop dispatcher librenms`
2. In a terminal that stays open: `docker compose run --rm --no-deps --name db-recovery db mysqld --skip-grant-tables --skip-networking`
3. In a second terminal run `docker exec -it db-recovery mariadb`, then:

   ```sql
   FLUSH PRIVILEGES;
   ALTER USER 'root'@'localhost' IDENTIFIED BY 'choose-a-strong-password';
   ALTER USER 'librenms'@'%' IDENTIFIED BY 'the-MYSQL_PASSWORD-from-.env-or-a-new-one';
   ```

   `SELECT user, host FROM mysql.user;` shows the exact account names. If you chose a new application password, put it
   in `.env` as `MYSQL_PASSWORD`.
4. Press Ctrl-C in the first terminal, then `docker compose up -d`.

Database lost or damaged instead? Restore a backup: `./run restore latest`.

## Optional services

Set `COMPOSE_PROFILES` in `.env`, then `docker compose up -d`:

| Profile | Adds | Port |
|---|---|---|
| `syslog` | syslog-ng receiver | `SYSLOG_PORT` (514 udp/tcp) |
| `traps` | snmptrapd receiver | `TRAP_PORT` (162 udp/tcp) |
| `ntopng` | ntopng Community traffic analytics (Linux hosts only) | `NTOPNG_WEB_PORT` (3000, localhost only) |
| `mail` | msmtpd relay for alert e-mail | none, internal only |
| `netflow` | NetFlow/sFlow collector with NfSen, feeds the LibreNMS Netflow tab | UDP 2055-2064 (`NFSEN_FLOW_PORT_FIRST` to `_LAST`), web UI `NFSEN_WEB_PORT` (8080, localhost only) |

Example: `COMPOSE_PROFILES=syslog,traps,ntopng,mail,netflow`. Point your devices at the host's address. The syslog and trap
receivers are published on every interface of the host, because devices have to reach them: see the next section to
restrict who can send.

### Firewall: published ports bypass UFW

On Linux, Docker publishes a port with its own iptables rules. They apply to forwarded traffic, so it never passes the
INPUT chain that UFW and firewalld manage: `ufw deny 514` does **not** block `SYSLOG_PORT`, `TRAP_PORT` or a web UI
published with `LIBRENMS_BIND=0.0.0.0`. Restrict them in one of two ways:

1. **Bind to one address.** Put the address into the variable: `SYSLOG_PORT=192.0.2.10:514` and
   `TRAP_PORT=192.0.2.10:162` (Compose then publishes `192.0.2.10:514:514/udp`). Only that address of the host
   listens. This also works on Docker Desktop.
2. **Filter in the `DOCKER-USER` chain**, which Docker evaluates first and never rewrites. This allows only your device
   subnet (replace `10.0.0.0/8`) and drops everything else. Use the port numbers you set in `.env`:

   ```bash
   for port in 514 162; do
     for proto in udp tcp; do
       sudo iptables -I DOCKER-USER -p "$proto" -m conntrack --ctorigdstport "$port" ! -s 10.0.0.0/8 -j DROP
     done
   done
   ```

   These rules are lost at reboot unless you save them (`netfilter-persistent` or your distribution's equivalent).
   Repeat with `ip6tables` if IPv6 is enabled. The same applies to the NetFlow ports (UDP 2055-2064 by default).

### Syslog

1. Set `COMPOSE_PROFILES=syslog` in `.env`, then `docker compose up -d`.
2. Turn syslog on in LibreNMS: `docker compose exec --user librenms librenms lnms config:set enable_syslog true`
   (or in the web UI under *Settings > Syslog*).
3. Point the device's syslog target at the host, port 514. LibreNMS keeps messages only from devices it knows, matched
   by address, so add the device first.
4. Test from any Linux machine: `logger -n <host-address> -P 514 -d "LibreNMS syslog test"`. The message appears on
   the device's *Logs > Syslog* tab.

### SNMP traps

1. Set `COMPOSE_PROFILES=traps` in `.env`, then `docker compose up -d`.
2. Point the device's trap target at the host, port 162, with the community (v1/v2c) or user (v3) configured on the
   device. Add the device in LibreNMS first: traps are matched to devices by source address.
3. Test from a machine whose address belongs to a device in LibreNMS, with net-snmp installed. This sends a coldStart trap:

   ```bash
   snmptrap -v2c -c <community> <host-address>:162 '' 1.3.6.1.6.3.1.1.5.1
   ```

   The event shows up in the device's *Logs > Eventlog*. `docker compose logs snmptrapd` shows what the receiver
   itself logged.
4. Nothing arrives? Check which communities and users the receiver accepts (the usual location is shown; see the
   image documentation if it differs): `docker compose exec snmptrapd cat /etc/snmp/snmptrapd.conf`

**SNMPv3 traps** are not preconfigured, because they need the sending device's engine ID and your own credentials.
To enable them, copy the receiver's current `snmptrapd.conf` from step 4, **keep its existing lines** (they hand the
traps to LibreNMS), add the two lines below with your own values, and mount the result over that path of the
`snmptrapd` service from a `compose.override.yaml`:

```
createUser -e 0x<engine-id-of-the-sending-device> <trap-user> SHA <auth-passphrase> AES <priv-passphrase>
authUser log,execute,net <trap-user> priv
```

`compose.override.yaml` and `snmptrapd.local.conf` are git-ignored, so the passphrases stay out of the repository.
Configure the same user, protocols and passphrases as the trap target on the device.

### ntopng (traffic analytics)

[ntopng](https://www.ntop.org/products/traffic-analysis/ntop/) Community Edition (official `ntop/ntopng` image, no
license key) shows which hosts talk to which, with which protocols and how much. It sits next to LibreNMS: LibreNMS
tells you whether a device is up and what its counters say, ntopng tells you what the traffic is.

**Capture method.** Live packet capture on one host network interface, ideally a mirror (SPAN) port of your switch.
ntopng sees only the traffic that reaches that interface. NetFlow/sFlow collection is not used: ntopng needs ntop's
separate nProbe for that, which is outside this project.

**Linux hosts only.** The container uses `network_mode: host`, the only way for a container to see the host's real
interfaces. On Docker Desktop (Windows, macOS) "host" is the Docker VM, where there is nothing worth capturing. Apart
from host networking it is **not privileged** and has just two capabilities, `NET_RAW` (capture) and `NET_ADMIN`
(promiscuous mode). A small dedicated Redis (`ntopng-redis`, `127.0.0.1:6380`, own volume) holds ntopng's users and
settings, so they survive container re-creation.

1. Find the interface with `ip -br link`. For a SPAN port use the NIC the mirror is plugged into. It must be up
   (`sudo ip link set <nic> up`) and needs no IP address.
2. In `.env` set `NTOPNG_INTERFACE=<nic>` and add `ntopng` to `COMPOSE_PROFILES`.
3. `docker compose up -d`, then open <http://localhost:3000>.
4. Log in as `admin` / `admin` and change the password when ntopng asks for it. Do it immediately, even though the
   UI only listens on localhost by default.

Check: `docker compose ps` shows `ntopng` healthy, and `ss -ltn` shows port 3000 on `127.0.0.1` only. To confirm that
settings persist, change the password, run `docker compose up -d --force-recreate ntopng`, and log in again with the
new one.

Settings in `.env`: `NTOPNG_WEB_PORT` (default 3000), `NTOPNG_BIND` (`127.0.0.1`; set `0.0.0.0` for other machines and
put TLS in front), `NTOPNG_REDIS_PORT` (6380), `NTOPNG_VERSION` (`latest`). Data lives in the volumes `librenms_ntopng`
and `librenms_ntopng-redis`. `scripts/backup.*` does not include them: they hold traffic history and ntopng settings only.

### NetFlow / sFlow (NfSen)

The `netflow` profile collects flows from your routers and switches and adds a **Netflow** tab to each matching
device in LibreNMS, with Flows, Packets and Traffic graphs. It has three parts:

- `nfsen` receives the flows. Every device ("source") exports to its own UDP port, where nfdump's collector
  (`nfcapd`, or `sfcapd` for sFlow) stores them and NfSen turns them into RRD files. The NfSen web UI is included.
- The volume `nfsen` is mounted **read only** at `/netflow` in the LibreNMS web container. LibreNMS does not collect
  flows: it only draws the RRD files that NfSen writes.
- `nfsen-perms` is a small helper that keeps those RRD files readable for LibreNMS (see "Permissions" below).

What you get is what the LibreNMS integration offers: graphs **per device**. It has no per-port view and no top-talker
tables; use the NfSen web UI for those (<http://localhost:8080/nfsen/>, no login, so it listens on localhost only
unless you set `NFSEN_BIND`). The *Stats* sub-page of the LibreNMS tab runs `nfdump` inside the LibreNMS container,
which this setup does not provide. Check with `docker compose exec librenms which nfdump`; only if it exists, point
LibreNMS at it with `lnms config:set nfdump <path>`.

**1. Define the sources and start.** In `.env`, one source per device, separated by `:`, each written
`name,port,colour,type`. Keep the single quotes, then add `netflow` to `COMPOSE_PROFILES`:

```
NFSEN_SOURCES='core_rtr,2055,#0000ff,netflow:edge_fw,2056,#ff0000,netflow:lab_sw,2057,#00aa00,sflow'
```

`name` is 1 to 19 letters, digits or underscores and must match the device in LibreNMS (see "Device names"), `port`
is a UDP port in the published range `NFSEN_FLOW_PORT_FIRST` to `NFSEN_FLOW_PORT_LAST` (2055 to 2064), and `type` is
`netflow` or `sflow`. Give every device its **own** port: that is how NfSen tells devices apart. If a device samples,
add its rate as a fifth field (`edge_fw,2056,#ff0000,netflow,-s -1000`). Then:

```bash
docker compose up -d
docker compose ps nfsen                                        # healthy after about a minute
docker compose logs -f nfsen
docker compose exec nfsen /usr/local/nfsen/bin/nfsen status   # the NfSen daemons
```

To add a device, extend `NFSEN_SOURCES` and run `docker compose up -d` again (it recreates the container; the data
stays). The name of a source is the key of its history: never rename one. To retire a device keep its name with port
`0` (`old_rtr,0,#0000ff,netflow`). New sources join the built-in `live` profile by themselves; custom NfSen profiles
need the new source added in the NfSen UI.

**2. Point the devices at the Docker host**, each at its own port (`192.0.2.10` stands for the host's address):

```
! Cisco IOS XE (Flexible NetFlow)
flow exporter NFSEN
 destination 192.0.2.10
 source Loopback0
 transport udp 2055
 export-protocol netflow-v9
flow monitor NFSEN-V4
 exporter NFSEN
 cache timeout active 60
 record netflow ipv4 original-input
interface GigabitEthernet0/0/1
 ip flow monitor NFSEN-V4 input
 ip flow monitor NFSEN-V4 output

! Cisco IOS, classic
ip flow-export version 9
ip flow-export destination 192.0.2.10 2055
ip flow-export source Loopback0
ip flow-cache timeout active 1
interface GigabitEthernet0/1
 ip flow ingress
 ip flow egress

# MikroTik RouterOS 7 (RouterOS 6 uses: address=192.0.2.10:2055)
/ip traffic-flow set enabled=yes interfaces=all active-flow-timeout=1m inactive-flow-timeout=15s
/ip traffic-flow target add dst-address=192.0.2.10 port=2055 version=9

# Linux soft-router, NetFlow v9 (softflowd)
sudo softflowd -i eth0 -n 192.0.2.10:2055 -v 9 -t maxlife=60

# Linux soft-router, sFlow (hsflowd.conf), matches the "sflow" source on port 2057
sflow {
  sampling = 400
  polling = 30
  collector { ip = 192.0.2.10 udpport = 2057 }
  pcap { dev = eth0 }
}
```

These are starting points: option names differ between software versions, so check the vendor documentation. On
Docker Desktop (Windows, macOS) the devices must reach the computer's LAN address, and the host firewall must allow the
UDP range.

**3. Tell LibreNMS where the files are.** Run `./run configure` (Windows: `.\scripts\run.ps1 configure` or `scripts\run.bat configure`). With the `netflow`
profile on, it applies the settings below; list entries are added only when missing, so it is safe to repeat, and
`--dry-run` only prints the commands. By hand, once, from the project folder:

```bash
docker compose exec --user librenms librenms lnms config:set nfsen_enable true
docker compose exec --user librenms librenms lnms config:set nfsen_split_char '_'
docker compose exec --user librenms librenms lnms config:set nfsen_rrds.+ '/netflow/nfsen/profiles-stat/live/'
docker compose exec --user librenms librenms lnms config:set nfsen_rrds.+ '/netflow/nfsen/profiles-stat'
docker compose exec --user librenms librenms lnms config:set nfsen_base.+ '/netflow/nfsen/'
```

`.+` adds an entry to a list each time, so run the by-hand lines once (`lnms config:get nfsen_rrds` shows the result). The same settings
are in the web UI under *Settings > External Settings > NFSen*. As `config.php` lines they read:

```php
$config['nfsen_enable'] = 1;
$config['nfsen_split_char'] = '_';
$config['nfsen_rrds'][] = '/netflow/nfsen/profiles-stat/live/';
$config['nfsen_rrds'][] = '/netflow/nfsen/profiles-stat';
$config['nfsen_base'][] = '/netflow/nfsen/';
```

The paths are the ones **inside the LibreNMS container**, where the volume is `/netflow`; inside the NfSen container
the same files are under `/data/nfsen`. `nfsen_suffix` (see below) and `nfdump` are the only other settings, and only
needed in the cases described there. If the UI refuses `nfsen_base` on your LibreNMS version, leave it out: the graphs
only need `nfsen_rrds`.

**4. Device names.** LibreNMS turns a device name into an RRD file name in three steps: every `.` becomes
`nfsen_split_char`, the optional `nfsen_suffix` is cut off the end, and `<result>.rrd` is looked up in each
`nfsen_rrds` folder. NfSen names the file after the source, and sources allow only letters, digits and `_`. So:

| Device in LibreNMS | NfSen source | What to do |
|---|---|---|
| `core_rtr` | `core_rtr` | Nothing, the names match. |
| `rtr1.example.com` | `rtr1_example_com` | Nothing (dots become `_`). Or call the source `rtr1` and set `lnms config:set nfsen_suffix '_example_com'`. |
| `core-sw1` (hyphen) | `core_sw1` | Add a link named like the device: see below. |
| `10.0.1.1` (added by IP) | `edge_fw` | `10_0_1_1.rrd` must point to `edge_fw.rrd`: see below. |

Create the link in the NfSen container, with a relative target so that it resolves in both containers (it may exist
before its target does):

```bash
docker compose exec nfsen sh -c 'cd /data/nfsen/profiles-stat/live && ln -s edge_fw.rrd 10_0_1_1.rrd'
```

The Netflow tab appears once the RRD file exists, which is 5 to 10 minutes after the first flows arrive: NfSen works
in 5-minute slots.

**5. Check that flows arrive.** On the Docker host, `sudo tcpdump -ni any udp port 2055` shows the packets, and
`docker compose exec nfsen ls -R /data/nfsen/profiles-data/live/core_rtr` shows the collector's files (a new one every
5 minutes). To test without a router, run `softflowd` from the list above on any Linux machine and generate some traffic.

**Permissions.** LibreNMS reads as its `librenms` user, which is `PUID`/`PGID` (1000 by default). The NfSen image keeps
its data as user `netflow` (also 1000) with group `www-data`, while the statistics are written by `www-data`. The helper
`nfsen-perms` makes the statistics folder (RRD files only, never the flow data) world-readable every minute, and
LibreNMS has no write access at all, so neither side can hit a permission error that needs fixing by hand. To see what
LibreNMS sees:

```bash
docker compose exec --user librenms librenms ls -l /netflow/nfsen/profiles-stat/live/
docker compose exec --user librenms librenms rrdtool info /netflow/nfsen/profiles-stat/live/core_rtr.rrd
```

"Permission denied" on a graph: wait a minute for the helper, or run
`docker compose exec nfsen chmod -R a+rX /data/nfsen/profiles-stat`. Do not enable `rrdcached` for LibreNMS: it
cannot read files outside its own folder, a known cause of NfSen graph errors. This stack does not use it.

**Data and disk.** Flows and RRD files live in the volume `librenms_nfsen`, which `scripts/backup.*` does not include
(copy the volume yourself if you need it). Check the size and lifetime limits of the `live` profile in the NfSen UI:
without a limit the flow files keep growing.

**The image.** There is no official NfSen image. The default is a community build of nfdump 1.7.x with NfSen 1.3.11
(`rguaitanele/docker-nfsen`, one maintainer), so pin `NFSEN_VERSION` to a tag from its Docker Hub page once it works
for you. Its published architectures could not be confirmed, so on Apple Silicon (or to pin the exact source) build
it yourself and point `.env` at the result:

```bash
docker build -t librenms-nfsen:local https://github.com/rguaitanele/docker-nfsen.git
```

then `NFSEN_IMAGE=librenms-nfsen` and `NFSEN_VERSION=local` (append `#<commit>` to the URL to pin a commit). The
compose file also sets PHP's time zone from `TZ`, because the image would otherwise show NfSen times in
America/Sao_Paulo. Everything about the image comes from its public Dockerfile; it has not been run as part of this
project.

### Email alerts (mail relay)

LibreNMS can send mail directly (*Settings > Alerting > Email options*). The `mail` profile adds a small relay,
[msmtpd](https://github.com/crazy-max/docker-msmtpd): LibreNMS hands its alert mail to the relay on the internal
network, and the relay logs in to your real SMTP server. The SMTP login then lives only in `.env`.

1. Fill in `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD` and `SMTP_FROM` in `.env`. Port 587 normally means
   `SMTP_STARTTLS=on`; port 465 means `SMTP_TLS=on` with `SMTP_STARTTLS=off`. Add `mail` to `COMPOSE_PROFILES`, then
   `docker compose up -d`.
2. Point LibreNMS at the relay: `./run configure` (Windows: `.\scripts\run.ps1 configure` or `scripts\run.bat configure`). LibreNMS keeps its mail settings
   in its database, so enabling the profile alone does not change them; `configure` sees that the `mail` profile is on
   and sets the backend, the host (`msmtpd`), the port (`2500`), no login, and the sender from `SMTP_FROM`. It is safe to
   repeat, and `--dry-run` only prints the commands. By hand, the same is:

   ```bash
   docker compose exec --user librenms librenms lnms config:set email_backend smtp
   docker compose exec --user librenms librenms lnms config:set email_smtp_host msmtpd
   docker compose exec --user librenms librenms lnms config:set email_smtp_port 2500
   docker compose exec --user librenms librenms lnms config:set email_smtp_auth false
   docker compose exec --user librenms librenms lnms config:set email_from "librenms@example.com"
   ```

   The same in the web UI (*Settings > Alerting > Email options*): backend `SMTP`, host `msmtpd`, port `2500`, no
   encryption, no authentication.
3. Test from the test button of a Mail transport under *Alerts > Alert Transports*. `docker compose logs msmtpd` shows
   the relay's side, including login errors from your SMTP server.

The setup scripts do not generate SMTP values, and `SMTP_PASSWORD` is stored like the other secrets in `.env` (mode
`600`, git-ignored). Put it in single quotes there if it contains `$` or `#`.

## HTTPS (reverse proxy)

To serve LibreNMS to other machines, keep `LIBRENMS_BIND=127.0.0.1` (the default) so that the web UI is reachable only
through a proxy that terminates TLS. Put the proxy in `compose.override.yaml`: Compose loads it automatically, and this
repository git-ignores it. You need a DNS name that points at the server and ports 80 and 443 reachable from the
internet, because Let's Encrypt checks the name that way. For a LAN-only name without public DNS use a certificate from
your own CA instead.

**Caddy** obtains and renews the certificate by itself. Replace `librenms.example.com` and save as `compose.override.yaml`:

```yaml
services:
  caddy:
    image: caddy:2
    command: caddy reverse-proxy --from librenms.example.com --to librenms:8000
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - caddy_data:/data        # keeps the certificate, so restarts do not ask Let's Encrypt again
      - caddy_config:/config
    depends_on:
      librenms:
        condition: service_healthy
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
    restart: unless-stopped

volumes:
  caddy_data:
  caddy_config:
```

Run `docker compose up -d`, watch `docker compose logs -f caddy` until the certificate is issued, then open
`https://librenms.example.com`. LibreNMS needs no setting for this: it is served at the root of the name. If it shows
the proxy's address as the client address, add the proxy to LibreNMS' trusted proxies setting (see the upstream
documentation on reverse proxies).

**Nginx** works the same way (`proxy_pass http://librenms:8000;` with `proxy_set_header Host $host;`,
`X-Forwarded-For $proxy_add_x_forwarded_for` and `X-Forwarded-Proto $scheme`), but it does not fetch certificates
itself: pair it with certbot, or with the `nginx-proxy` and `acme-companion` images. Caddy is the shorter route.
Ports 80 and 443 are published on every interface by design; see the firewall section above if you need to narrow that.

## Tuning

Set these in `.env`, then `docker compose up -d` (MariaDB restarts for a moment):

| Variable | Default | Meaning |
|---|---|---|
| `MARIADB_BUFFER_POOL_SIZE` | `512M` | RAM that MariaDB uses to cache tables and indexes. Raise it on a large installation (for example `2G`), lower it on a small VM, and keep it below the memory Docker may use (Docker Desktop: *Settings > Resources*). |
| `MARIADB_MAX_CONNECTIONS` | `250` | Simultaneous database connections. Raise it if LibreNMS logs "Too many connections". |
| `DISPATCHER_WORKERS` | `8` | Poller workers: how many devices are polled at the same time. |

`DISPATCHER_WORKERS` is handed to the dispatcher container. LibreNMS itself keeps the worker count in its own setting
`service_poller_workers` (*Settings > Poller*), and whether an image version honours the variable depends on that
image. So `./run configure` also writes the number there; then run `./run restart dispatcher`. By hand:

```bash
docker compose exec --user librenms librenms lnms config:set service_poller_workers 8
docker compose restart dispatcher
```

Fixed settings, chosen for LibreNMS' many small writes. `innodb_flush_log_at_trx_commit=2` writes the database log to
disk once a second instead of at every commit, which removes most of the disk writes. The price: a power failure or an
operating-system crash can lose the last second of changes (a crash of MariaDB itself loses nothing), which is normally
acceptable for monitoring data. `innodb_log_file_size=128M` makes checkpoints less frequent, and MariaDB gets 60 seconds
to shut down cleanly. Container logs rotate at 3 files of 20 MB per container, so `docker compose logs` reaches back
only as far as what is kept. Backups skip logs and cache, as described above.

## Platform notes

**Windows**

- If `scripts\setup.ps1` is blocked, run it as shown above (`-ExecutionPolicy Bypass` applies to that one run).
- Line endings are controlled by `.gitattributes`: shell scripts stay LF (they also run inside Linux containers).
  Do not re-save them with an editor that converts to CRLF.
- Using WSL instead? Clone inside the WSL filesystem, enable *Docker Desktop > Settings > Resources > WSL integration*
  for your distribution, and use `scripts/setup.sh` from there.
- The setup script maps your Windows time zone to an IANA name for a short list of common zones. If yours is not
  covered it uses `UTC` and tells you; set `TZ` in `.env` (for example `Asia/Ho_Chi_Minh`).

**macOS**

- Docker Desktop is the tested path. Other runtimes that provide `docker compose` (OrbStack, Colima) should work but
  are not tested here.
- The bundled `bash` is 3.2; the scripts are written for it.

**Linux**

- Non-root users need to be in the `docker` group (or use `sudo`).
- Rootless Docker cannot bind ports below 1024: set `SYSLOG_PORT` and `TRAP_PORT` to high ports and configure
  devices accordingly.
- SELinux hosts (Fedora, RHEL): add `:z` to the two bind mounts of the `tools` service in `compose.yaml`
  (`./backups` and `bash scripts/container`) if backup or restore reports permission errors.
- Something else already listens on UDP 514 or 162 (rsyslog, a host snmptrapd)? Change `SYSLOG_PORT` / `TRAP_PORT`.
- The `ntopng` profile uses host networking, so ports 3000 and 6380 of the host must be free (`NTOPNG_WEB_PORT`,
  `NTOPNG_REDIS_PORT`).
- The `netflow` profile publishes UDP 2055-2064 and the NfSen web UI port (8080): they must be free on the host.

**All platforms**

- The web UI listens on `127.0.0.1` only. To reach it from other machines set `LIBRENMS_BIND=0.0.0.0` in `.env`,
  and put a reverse proxy with TLS in front of it ([recipe](#https-reverse-proxy)).
- Polling works from inside the container (SNMP and ICMP leave through Docker's NAT). The "localhost" device LibreNMS
  creates is the **container**, not your computer; add your computer by its IP address like any other device.
- Docker Desktop (Windows, macOS) runs containers in a VM, and incoming syslog and trap packets can arrive with the
  VM's address instead of the sender's. If you rely on source addresses for syslog or traps, a Linux host avoids this.
- Data lives in Docker **named volumes** (`librenms_db`, `librenms_data`), not in bind mounts. That avoids the slow
  file sharing and permission problems that bind-mounted databases have on Windows and macOS.
  `docker compose down -v` deletes them.

## Security

- All secrets are generated into `.env` (mode `600`, git-ignored). To start from scratch run
  `docker compose down -v`, delete `.env`, and run the setup script again. Do not just delete `.env`: the database keeps
  the old password until its volume is recreated.
- The generated SNMP community only affects the LibreNMS container's own SNMP agent. Credentials for your devices are
  entered in the web UI and stored in the database (so backups are sensitive).
- MariaDB and Redis publish no ports: they are reachable only from the other containers. Only the web UI (localhost by
  default), the optional receivers (514, 162) and the optional ntopng UI (localhost by default) are exposed.
- ntopng ships with the login `admin` / `admin` and asks you to change it on the first visit. Do that before anything else.
- The NfSen web UI has no login, so it listens on localhost only. Do not set `NFSEN_BIND=0.0.0.0` without a reverse
  proxy that asks for a password. The flow ports are open to every sender unless you restrict them (see Firewall).
- Nothing runs privileged. Only the web and dispatcher containers (ICMP polling) and ntopng (packet capture) get
  `NET_ADMIN` and `NET_RAW`. The syslog and trap receivers get neither, and `nfsen-perms` keeps just `FOWNER` and
  `DAC_OVERRIDE` on a read-only root filesystem. The core services (`librenms`, `dispatcher`, `db`, `redis`) are left as
  they were on purpose: stricter settings such as `no-new-privileges` or `read_only` might stop ICMP polling or the
  images' start-up, and could not be tried against a real Docker while this was written.
- The mail relay is not published on the host. It does not ask LibreNMS to log in, so only attach containers to this
  Compose network that you trust.
- Use SNMPv3 authPriv for your devices where possible, restrict SNMP by source address on them, and use a strong admin
  password. Do not expose the web UI to the internet without TLS.

## Troubleshooting

| Symptom | What to do |
|---|---|
| "MYSQL_PASSWORD is empty" | `.env` is missing or was copied from the template by hand. Run the setup script. |
| Setup says the Docker daemon is not running | Start Docker Desktop (Windows, macOS) or `sudo systemctl start docker` (Linux). |
| `up --wait` times out | `docker compose ps` and `docker compose logs librenms db`. The first start can take 5 minutes or more on slow disks or with little RAM. |
| Port 8000 is in use | Set `LIBRENMS_PORT` in `.env`. |
| Devices stay empty, nothing is polled | `docker compose ps`: the `dispatcher` service must be running. |
| Cannot reach the UI from another computer | `LIBRENMS_BIND=0.0.0.0` in `.env`, then `docker compose up -d`; check the host firewall. |
| Backup or restore: permission denied | See the SELinux note above. |
| `ntopng` is unhealthy or keeps restarting | `docker compose logs ntopng ntopng-redis`. Usual causes: `NTOPNG_INTERFACE` is not a real interface (`ip -br link`), or port 3000 or 6380 is already in use on the host. |
| ntopng shows no traffic | It only sees what reaches `NTOPNG_INTERFACE`: check the switch mirror (SPAN) configuration. On Windows and macOS it cannot work (Linux only). |
| `restore` says both files "must both exist" | Name a backup that has a `-db.sql.gz` and a `-data.tgz` file in `./backups`: `latest`, a timestamp, or a path to either file. |
| Alert e-mail does not arrive | `docker compose logs msmtpd` (login or TLS errors from your SMTP server), and check that LibreNMS points at host `msmtpd`, port `2500`. |
| "Too many connections" | Raise `MARIADB_MAX_CONNECTIONS` in `.env` (see Tuning). |
| `./run update` says the stack did not become healthy | `./run logs`; to go back see "Updating" above. |
| Anything odd after changing `.env` | `./run doctor` first. |
| `./run configure` says LibreNMS is not running | Start it first (`./run up`); `--dry-run` works without Docker. |
| No Netflow tab on a device | The RRD file must exist and be named like the device (README, "Device names"); the settings in step 3 must be in place; allow 5 to 10 minutes after the first flows. |
| Netflow graph says "Permission denied" or stays empty | See "Permissions" above, and make sure `rrdcached` is not enabled in LibreNMS. |
| No files appear under `profiles-data` | The device does not reach its port: check `tcpdump`, the firewall, and that the source's port is inside the published range and different for every device. |

## Tests

`bash tests/all.sh` runs every test. None needs Docker: a fake `docker` records the calls, so the scripts can be
checked anywhere bash runs.

| File | What it checks |
|---|---|
| `tests/test_launcher.sh` | Each `run` verb issues the right command, mistakes are refused, `restore` accepts every way of naming a backup. |
| `tests/test_configure_update.sh` | `configure` (settings from `.env`, whole-entry matching, safe to repeat) and `update` (backup first, then pull and restart). |
| `tests/test_doctor.sh` | `doctor` finds bad `NFSEN_SOURCES` entries, missing secrets, memory problems and exposed web UIs, and stays quiet on a healthy setup. |
| `tests/test_backup_tar.sh` | The backup archive leaves out logs and cache and keeps everything else (needs GNU tar). |
| `tests/test_compose.py` | The real `docker compose config` of every profile, and the shell scripts embedded in `compose.yaml`. Skipped without Docker. |

CI runs them on Ubuntu and macOS (the macOS run checks the bash 3.2 that macOS ships) and, in the `profiles` job, starts
every optional profile for real. The macOS run and the `profiles` job are new: they are marked "continue on error"
until they have passed once, so remove that setting from `.github/workflows/ci.yml` after the first green run.

## Repository layout

```
compose.yaml                 the stack (web, dispatcher, db, redis, optional syslog/traps/ntopng/mail/netflow, tools helper)
.env.example                 template; scripts/setup.* turn it into .env
run                          universal cross-platform launcher (delegates to scripts/run.sh or scripts/run.bat)
scripts/run.sh               Bash launcher: up, down, restart, logs, status, backup, restore, validate, configure, update, doctor
scripts/run.bat              Windows CMD batch launcher (delegates to scripts/run.ps1)
scripts/run.ps1              PowerShell launcher for Windows
scripts/setup.sh|ps1         create .env with random secrets and start
scripts/backup.sh|ps1        back up database and data
scripts/restore.sh|ps1       restore from a backup
scripts/container/*.sh       the logic that runs inside the helper container
tests/                       script tests with a fake docker, run by tests/all.sh and by CI
.github/workflows/ci.yml     tests on Linux, macOS, Windows
```

## Publish this repository to GitHub

```bash
git init -b main
git add .
git status                    # check: .env and backups/ must NOT be listed
git commit -m "LibreNMS on Docker"
```

With the [GitHub CLI](https://cli.github.com/):

```bash
gh repo create librenms-docker --private --source=. --push
```

Or create an empty repository on github.com and:

```bash
git remote add origin https://github.com/<you>/librenms-docker.git
git push -u origin main
```

The CI workflow starts on the first push (*Actions* tab). Keep the repository **private** if your `compose.yaml`
ever gains site-specific details. The files here contain no secrets.

## Credits and licence

This project only wires together the upstream images
([librenms/librenms](https://hub.docker.com/r/librenms/librenms), [MariaDB](https://hub.docker.com/_/mariadb),
[Redis](https://hub.docker.com/_/redis), and for the optional parts [ntopng](https://hub.docker.com/r/ntop/ntopng),
[nfdump](https://github.com/phaag/nfdump) and [NfSen](https://github.com/phaag/nfsen) (in the community image
[docker-nfsen](https://github.com/rguaitanele/docker-nfsen)),
[msmtpd](https://hub.docker.com/r/crazymax/msmtpd) and [Caddy](https://hub.docker.com/_/caddy)). LibreNMS is GPL-licensed; see the upstream projects for their terms. Add a
licence file of your choice for the scripts and configuration in this repository.

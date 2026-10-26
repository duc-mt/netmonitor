#!/usr/bin/env python3
"""Checks on the real `docker compose config` output of compose.yaml: the default stack and every profile.
It also runs the shell scripts that compose.yaml embeds (ntopng healthcheck, NfSen time zone and permissions).
Skipped (exit 0) when `docker compose` is not available. Standard library only."""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = 0


def check(label, condition, detail=""):
    global failures
    if condition:
        print(f"  ok    {label}")
    else:
        failures += 1
        print(f"  FAIL  {label}" + (f"\n        {detail}" if detail else ""))


def compose_available():
    try:
        return subprocess.run(["docker", "compose", "version"], capture_output=True).returncode == 0
    except OSError:
        return False


def render(profiles, extra=None):
    """The services compose.yaml defines for these profiles, as `docker compose config --format json` reports them."""
    with tempfile.TemporaryDirectory() as tmp:
        shutil.copy(os.path.join(ROOT, "compose.yaml"), tmp)
        with open(os.path.join(ROOT, ".env.example")) as f:
            text = f.read()
        text = text.replace("MYSQL_PASSWORD=\n", "MYSQL_PASSWORD=test\n")
        text = text.replace("LIBRENMS_SNMP_COMMUNITY=\n", "LIBRENMS_SNMP_COMMUNITY=test\n")
        with open(os.path.join(tmp, ".env"), "w") as f:
            f.write(text)
        env = dict(os.environ, COMPOSE_PROFILES=profiles)
        env.update(extra or {})
        result = subprocess.run(["docker", "compose", "config", "--format", "json"], cwd=tmp, env=env,
                                capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit("docker compose config failed:\n" + result.stderr)
        return json.loads(result.stdout)["services"]


def mounts(service):
    """Volume entries as dicts (compose config already reports them that way; the short form is handled too)."""
    found = []
    for v in service.get("volumes") or []:
        if isinstance(v, str):
            parts = v.split(":")
            found.append({"source": parts[0], "target": parts[1], "read_only": parts[-1] == "ro", "nocopy": False})
        else:
            found.append({"source": v.get("source"), "target": v.get("target"), "read_only": bool(v.get("read_only")),
                          "nocopy": bool((v.get("volume") or {}).get("nocopy"))})
    return found


def run_script(script, env_path, extra_env=None):
    # Compose yaml uses $$ to escape literal $; unescape for standalone execution
    script = script.replace("$$", "$")
    env = {"PATH": env_path}
    env.update(extra_env or {})
    return subprocess.run(["/bin/sh", "-c", script], env=env, capture_output=True, text=True)


def main():
    if not compose_available():
        print("  skip  docker compose is not available")
        return 0

    DEFAULT = {"db", "redis", "librenms", "dispatcher"}
    EXTRA = {"syslog": {"syslogng"}, "traps": {"snmptrapd"}, "ntopng": {"ntopng", "ntopng-redis"},
             "mail": {"msmtpd"}, "netflow": {"nfsen", "nfsen-perms"}, "tools": {"tools"}}

    print("which services each profile adds")
    check("default stack", set(render("")) == DEFAULT, str(sorted(render(""))))
    for profile, added in EXTRA.items():
        names = set(render(profile))
        check(f"profile {profile}", names == DEFAULT | added, str(sorted(names)))

    everything = render(",".join(EXTRA))
    print("every profile together")
    LOGGED = set(everything) - {"tools"}
    bad = [n for n in LOGGED if (everything[n].get("logging") or {}).get("driver") != "json-file"
           or everything[n]["logging"].get("options", {}).get("max-size") != "20m"
           or str(everything[n]["logging"]["options"].get("max-file")) != "3"]
    check("log rotation (json-file, 20m x 3) on every long-running service", not bad, f"missing on {bad}")
    check("no privileged service", not [n for n, s in everything.items() if s.get("privileged")])
    check("host networking only for ntopng and its Redis",
          sorted(n for n, s in everything.items() if s.get("network_mode") == "host") == ["ntopng", "ntopng-redis"])

    print("capabilities")
    caps = lambda name, key: set(everything[name].get(key) or [])
    for name in ("librenms", "dispatcher"):
        check(f"{name} keeps NET_ADMIN and NET_RAW (ICMP polling)", caps(name, "cap_add") == {"NET_ADMIN", "NET_RAW"}, str(caps(name, "cap_add")))
    for name in ("syslogng", "snmptrapd"):
        check(f"{name} has no extra capabilities", not caps(name, "cap_add"), str(caps(name, "cap_add")))
        check(f"{name} has no raw sockets", "NET_RAW" in caps(name, "cap_drop"), str(caps(name, "cap_drop")))
    check("ntopng gets only NET_ADMIN and NET_RAW", caps("ntopng", "cap_add") == {"NET_ADMIN", "NET_RAW"}, str(caps("ntopng", "cap_add")))
    check("nfsen-perms drops everything", caps("nfsen-perms", "cap_drop") == {"ALL"})
    check("nfsen-perms adds back only FOWNER and DAC_OVERRIDE", caps("nfsen-perms", "cap_add") == {"FOWNER", "DAC_OVERRIDE"})
    check("nfsen-perms has a read-only root filesystem", everything["nfsen-perms"].get("read_only") is True)

    print("MariaDB and dispatcher settings")
    db_command = everything["db"]["command"]
    for flag in ("--innodb-buffer-pool-size=512M", "--innodb-flush-log-at-trx-commit=2",
                 "--innodb-log-file-size=128M", "--max-connections=250"):
        check(f"db {flag}", flag in db_command)
    check("DISPATCHER_WORKERS reaches the dispatcher", everything["dispatcher"]["environment"].get("DISPATCHER_WORKERS") == "8")
    tuned = render("", {"MARIADB_BUFFER_POOL_SIZE": "2G", "MARIADB_MAX_CONNECTIONS": "400"})["db"]["command"]
    check("tuning variables are honoured", "--innodb-buffer-pool-size=2G" in tuned and "--max-connections=400" in tuned)

    print("NetFlow volume")
    check("librenms mounts the NetFlow data read only at /netflow",
          {"source": "nfsen", "target": "/netflow", "read_only": True, "nocopy": False} in mounts(everything["librenms"]))
    check("no other LibreNMS container mounts it",
          not [n for n in ("dispatcher", "syslogng", "snmptrapd") if any(m["target"] == "/netflow" for m in mounts(everything[n]))])
    for name in ("nfsen", "nfsen-perms"):
        check(f"{name} mounts it at /data starting empty (nocopy)",
              {"source": "nfsen", "target": "/data", "read_only": False, "nocopy": True} in mounts(everything[name]))
    perms = everything["nfsen-perms"]
    check("nfsen-perms has no network", perms.get("network_mode") == "none")
    check("nfsen-perms has a minimal healthcheck", (perms.get("healthcheck") or {}).get("test") == ["CMD", "true"])
    check("nfsen sources default", everything["nfsen"]["environment"].get("NFSEN_SOURCES") == "router1,2055,#0000ff,netflow")
    other = render("netflow", {"NFSEN_IMAGE": "my-nfsen", "NFSEN_VERSION": "local"})["nfsen"]
    check("NFSEN_IMAGE and NFSEN_VERSION select the image", other["image"] == "my-nfsen:local", other["image"])

    print("embedded scripts")
    with tempfile.TemporaryDirectory() as work:
        # NfSen time zone: PHP's zone is set from TZ before the image's own entrypoint runs
        entry = everything["nfsen"]["entrypoint"]
        check("nfsen entrypoint is /bin/sh -c <script>", entry[:2] == ["/bin/sh", "-c"] and len(entry) == 3)
        conf_d = os.path.join(work, "conf.d")
        os.makedirs(conf_d)
        script = entry[2].replace("/usr/local/etc/php/conf.d", conf_d).replace(
            "exec /usr/local/bin/docker-entrypoint", "echo ENTRYPOINT-REACHED")
        result = run_script(script, os.environ["PATH"], {"TZ": "Asia/Ho_Chi_Minh"})
        with open(os.path.join(conf_d, "zz-timezone.ini")) as f:
            ini = f.read().strip()
        check("PHP time zone follows TZ", ini == "date.timezone=Asia/Ho_Chi_Minh" and "ENTRYPOINT-REACHED" in result.stdout, ini)
        run_script(script, os.environ["PATH"])
        with open(os.path.join(conf_d, "zz-timezone.ini")) as f:
            check("PHP time zone falls back to UTC", f.read().strip() == "date.timezone=UTC")

        # nfsen-perms: one pass of the loop makes statistics readable and leaves flow data alone
        body = [l for l in perms["entrypoint"][2].splitlines() if "chmod" in l][0].strip()
        stats = os.path.join(work, "data", "nfsen", "profiles-stat", "live")
        flows = os.path.join(work, "data", "nfsen", "profiles-data", "live", "router1")
        os.makedirs(stats)
        os.makedirs(flows)
        rrd, flow = os.path.join(stats, "router1.rrd"), os.path.join(flows, "nfcapd.1")
        for path in (rrd, flow):
            with open(path, "w") as f:
                f.write("x")
            os.chmod(path, 0o600)
        os.chmod(stats, 0o700)
        run_script(body.replace("/data/nfsen", os.path.join(work, "data", "nfsen")), os.environ["PATH"])
        mode = lambda p: stat.S_IMODE(os.stat(p).st_mode)
        check("nfsen-perms: RRD file becomes world-readable", mode(rrd) & 0o004 != 0, oct(mode(rrd)))
        check("nfsen-perms: statistics folder becomes searchable", mode(stats) & 0o005 == 0o005, oct(mode(stats)))
        check("nfsen-perms: flow data is left alone", mode(flow) == 0o600, oct(mode(flow)))

        # ntopng healthcheck: curl, else wget, else a look for the process
        test = everything["ntopng"]["healthcheck"]["test"]
        check("ntopng healthcheck is a CMD-SHELL script", test[0] == "CMD-SHELL")
        hc = test[1]
        bindir = os.path.join(work, "bin")
        os.makedirs(bindir)

        def fake(name, code):
            path = os.path.join(bindir, name)
            with open(path, "w") as f:
                f.write(f"#!/bin/sh\nexit {code}\n")
            os.chmod(path, 0o755)

        def clear():
            for n in ("curl", "wget", "ntopng"):
                if os.path.exists(os.path.join(bindir, n)):
                    os.remove(os.path.join(bindir, n))

        for label, tools, healthy in (("curl answers", {"curl": 0}, True), ("curl: server down", {"curl": 7}, False),
                                      ("curl: HTTP error", {"curl": 22}, False), ("no curl, wget answers", {"wget": 0}, True),
                                      ("no curl, wget: server down", {"wget": 1}, False)):
            clear()
            for n, c in tools.items():
                fake(n, c)
            code = run_script(hc, bindir).returncode
            check(f"ntopng healthcheck: {label}", (code == 0) == healthy, f"exit {code}")
        clear()
        check("ntopng healthcheck: no client and no process is unhealthy", run_script(hc, bindir).returncode != 0)
        if os.path.isdir("/proc/self") and shutil.which("sleep"):
            shutil.copy(shutil.which("sleep"), os.path.join(bindir, "ntopng"))     # a process named ntopng
            proc = subprocess.Popen([os.path.join(bindir, "ntopng"), "60"])
            time.sleep(0.3)
            check("ntopng healthcheck: no client but the process runs is healthy", run_script(hc, bindir).returncode == 0)
            proc.kill()
            proc.wait()

    print("PASSED" if failures == 0 else f"{failures} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

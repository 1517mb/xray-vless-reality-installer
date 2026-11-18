"""Installer regressions with temporary files and mocked services.

Run with: python -m unittest discover -s tests -v
Optional environment variables: BASH_BIN, JQ_BIN, XRAY_TEST_BIN.
No test installs packages, contacts the network, or writes to system directories.
"""

import base64
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ("xray-install.sh", "xray-install-docker.sh")
DOCKER_DEPLOY_MOCK = r'''#!/usr/bin/env bash
set -eu
printf '%s\t' "$@" >> "$TEST_ROOT/docker-calls"
printf '\n' >> "$TEST_ROOT/docker-calls"
case "$1 ${2:-}" in
    'info --format')
        if [[ "$DOCKER_TEST_SCENARIO" == engine-unavailable ]]; then exit 1; fi
        printf 'linux\n'
        ;;
    'container inspect')
        case "$DOCKER_TEST_SCENARIO" in
            stopped)
                if [[ "$4" == *Label* ]]; then printf '%s\n' "$XRAY_DOCKER_NAME"
                elif [[ "$4" == *Running* ]]; then printf 'false\n'
                elif [[ "$4" == *PortBindings* ]]; then printf '%s\n' "$XRAY_DOCKER_PORT"
                else exit 99; fi
                ;;
            foreign-container) printf 'foreign\n' ;;
            *) exit 1 ;;
        esac
        ;;
    'volume inspect')
        if [[ "$DOCKER_TEST_SCENARIO" == foreign-volume ]]; then
            printf 'foreign\n'
        elif [[ -f "$TEST_ROOT/volume-created" ]]; then
            printf '%s\n' "$XRAY_DOCKER_NAME"
        else
            exit 1
        fi
        ;;
    'volume create')
        : > "$TEST_ROOT/volume-created"
        printf '%s-config\n' "$XRAY_DOCKER_NAME"
        ;;
    'image inspect')
        if [[ "$DOCKER_TEST_SCENARIO" == foreign-image ]]; then
            printf 'foreign\n'
        else
            exit 1
        fi
        ;;
    'build '*)
        context="${@: -1}"
        cp -- "$context/xray-install-docker.sh" "$TEST_ROOT/built-installer.sh"
        cat > "$TEST_ROOT/built-dockerfile"
        ;;
    'run '*)
        if [[ "$DOCKER_TEST_SCENARIO" == configure-fails ]]; then exit 7; fi
        ;;
    'container create') printf 'created-container\n' ;;
    'container start'|'exec '*) ;;
    *)
        printf 'UNEXPECTED_DOCKER_COMMAND %s\n' "$*" >&2
        exit 99
        ;;
esac
'''
DOCKER_INSTALL_MOCK = r'''
export TMPDIR="$TEST_ROOT"
unset DOCKER_HOST DOCKER_CONTEXT
uname() { printf 'Linux\n'; }
download_fixture() {
    local destination=""
    printf '%s\n' "$@" > "$TEST_ROOT/docker-download-args"
    while (( $# )); do
        case "$1" in
            -o|-O|--output) destination="$2"; shift ;;
        esac
        shift
    done
    [[ "$destination" == "$TEST_ROOT/"* ]] || { echo UNEXPECTED_DOWNLOAD_PATH >&2; return 99; }
    cat > "$destination" <<'DOWNLOADED'
printf '%s\n' "$@" > "$TEST_ROOT/docker-install-args"
DOWNLOADED
    return "$DOWNLOAD_STATUS"
}
curl() { download_fixture "$@"; }
wget() { download_fixture "$@"; }
sudo() {
    [[ "$*" != -v ]] || return 0
    if [[ "$1" == -- ]]; then shift; fi
    case "$1" in
        sh|docker|systemctl) "$@" ;;
        *) echo UNEXPECTED_SUDO >&2; return 99 ;;
    esac
}
'''
# Public, test-only X25519 Alice vector from RFC 7748 section 6.1.
# https://www.rfc-editor.org/rfc/rfc7748.html#section-6.1
PUBLIC_KEY = base64.urlsafe_b64encode(bytes.fromhex(
    "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
)).decode().rstrip("=")
PRIVATE_KEY = base64.urlsafe_b64encode(bytes.fromhex(
    "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
)).decode().rstrip("=")
FIRST_UUID = "00000000-0000-4000-8000-000000000001"
SECOND_UUID = "00000000-0000-4000-8000-000000000002"


def shell_path(path):
    value = str(path).replace("\\", "/")
    if os.name == "nt" and re.match(r"^[A-Za-z]:/", value):
        value = "/" + value[0].lower() + value[2:]
    return value


def find_bash():
    if os.environ.get("BASH_BIN"):
        return os.environ["BASH_BIN"]
    if os.name == "nt":
        git_bash = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
        if git_bash.is_file():
            return str(git_bash)
    return shutil.which("bash")


class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bash = find_bash()
        if not cls.bash:
            raise unittest.SkipTest("Bash is required; set BASH_BIN")
        cls.libraries = {}
        for name in SCRIPTS:
            source = (ROOT / name).read_text(encoding="utf-8")
            marker = "# This script must be executed as root"
            if marker not in source:
                raise AssertionError(f"Cannot safely isolate functions in {name}")
            cls.libraries[name] = source.split(marker, 1)[0]
        cls.env = os.environ.copy()
        if cls.env.get("XRAY_TEST_BIN"):
            cls.env["XRAY_TEST_BIN"] = shell_path(Path(cls.env["XRAY_TEST_BIN"]).resolve())
        if cls.env.get("JQ_BIN"):
            if cls.env["JQ_BIN"].lower().endswith(".exe"):
                cls.env["JQ_TEST_BINARY_OUTPUT"] = "1"
            cls.env["JQ_BIN"] = shell_path(cls.env["JQ_BIN"])
        probe = subprocess.run(
            [cls.bash, "--noprofile", "--norc", "-c",
             'if [[ -n "${JQ_BIN:-}" ]]; then "$JQ_BIN" --version; else jq --version; fi'],
            env=cls.env, capture_output=True, text=True, timeout=10,
        )
        cls.has_jq = probe.returncode == 0
        openssl_probe = subprocess.run(
            [cls.bash, "--noprofile", "--norc", "-c", "openssl version"],
            env=cls.env, capture_output=True, text=True, timeout=10,
        )
        cls.has_openssl = openssl_probe.returncode == 0

    @contextlib.contextmanager
    def fixture(self, count=2):
        with tempfile.TemporaryDirectory(prefix="xray-regression-") as directory:
            root = Path(directory)
            config = {
                "marker": "old",
                "inbounds": [{
                    "port": 443, "protocol": "vless",
                    "settings": {"clients": [
                        {"id": f"00000000-0000-4000-8000-{i:012d}", "flow": "xtls-rprx-vision"}
                        for i in range(1, count + 1)
                    ]},
                    "streamSettings": {
                        "network": "tcp", "security": "reality",
                        "realitySettings": {
                            "privateKey": PRIVATE_KEY,
                            "serverNames": ["example.org"],
                            "shortIds": ["aabbccdd", "11223344"],
                        },
                    },
                }],
            }
            (root / "config.json").write_text(json.dumps(config), encoding="utf-8")
            (root / "server.addr").write_text("vpn.example.net\n", encoding="utf-8")
            binary = root / "xray-stub"
            binary.write_text(
                "#!/usr/bin/env bash\n"
                "set -eu\n"
                "case \"$1\" in\n"
                " x25519)\n"
                "  [[ \"${2:-}\" != -i ]] || { echo UNEXPECTED_XRAY_DERIVATION >&2; exit 99; }\n"
                f"  printf 'PrivateKey: {PRIVATE_KEY}\\nPassword: {PUBLIC_KEY}\\n'\n"
                "  ;;\n"
                " run)\n"
                "  [[ \"${2:-}\" == -test ]] || printf '%s\\n' \"$$\" > \"$TEST_ROOT/exec-pid\"\n"
                "  printf 'run' >> \"$TEST_ROOT/launched\"; printf ' %s' \"$@\" >> \"$TEST_ROOT/launched\"; printf '\\n' >> \"$TEST_ROOT/launched\" ;;\n"
                " *) exit 2 ;;\n"
                "esac\n",
                encoding="utf-8", newline="\n",
            )
            binary.chmod(0o755)
            yield root, config

    def run_shell(self, name, directory, body, *, success=True):
        env = self.env.copy()
        env["TEST_ROOT"] = shell_path(directory)
        setup = r'''
CONFIG="$TEST_ROOT/config.json"
SERVER_ADDR_FILE="$TEST_ROOT/server.addr"
XRAY_BIN="$TEST_ROOT/xray-stub"
XRAY_LOG="$TEST_ROOT/xray.log"
LOCK_FILE="$TEST_ROOT/installer.lock"
SERVICE_FILE="$TEST_ROOT/xray.service"
LOGROTATE_CONF="$TEST_ROOT/logrotate.d/xray-installer"
if [[ -n "${JQ_BIN:-}" ]]; then
    # Native Windows jq otherwise emits CRLF into Bash's read loops.
    jq() {
        if [[ "${JQ_TEST_BINARY_OUTPUT:-}" == 1 ]]; then "$JQ_BIN" -b "$@"
        else "$JQ_BIN" "$@"; fi
    }
fi
chown() { :; }
sleep() { :; }
install_deps() { echo UNEXPECTED_INSTALL >&2; return 99; }
curl() { echo UNEXPECTED_NETWORK >&2; return 99; }
systemctl() { echo UNEXPECTED_SERVICE >&2; return 99; }
qrencode() { :; }
'''
        if os.name == "nt":
            # Git Bash may report inaccessible Windows ancestors even when the
            # specific temporary directory already exists and is writable.
            setup += r'''
mkdir() {
    if [[ "$1" == -p && -d "${@: -1}" ]]; then return 0; fi
    command mkdir "$@"
}
'''
        result = subprocess.run(
            [self.bash, "--noprofile", "--norc"],
            input=self.libraries[name] + "\n" + setup + "\n" + body + "\n",
            text=True, encoding="utf-8", capture_output=True, env=env, timeout=20,
        )
        self.assertNotIn("UNEXPECTED_", result.stderr, result.stderr)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def run_docker_deploy(self, directory, scenario):
        installer = directory / "standalone" / "install docker.sh"
        installer.parent.mkdir()
        shutil.copyfile(ROOT / "xray-install-docker.sh", installer)
        mock = directory / "bin" / "docker"
        mock.parent.mkdir()
        mock.write_text(DOCKER_DEPLOY_MOCK, encoding="utf-8", newline="\n")
        mock.chmod(0o755)
        prelude = directory / "prelude.sh"
        prelude.write_text(
            r'''
export PATH="$TEST_ROOT/bin:$PATH"
mkdir() {
    local destination="${@: -1}"
    if [[ "$destination" != "$TEST_ROOT/"* ]]; then
        printf 'UNEXPECTED_MKDIR %s\n' "$destination" >&2
        exit 99
    fi
    command mkdir "$@"
}
''',
            encoding="utf-8", newline="\n",
        )
        env = self.env.copy()
        env.update(
            BASH_ENV=shell_path(prelude),
            TEST_ROOT=shell_path(directory),
            TMPDIR=shell_path(directory),
            DOCKER_TEST_SCENARIO=scenario,
            XRAY_DOCKER_NAME="test-xray",
            XRAY_DOCKER_PORT="8443",
            XRAY_SERVER_ADDRESS="vpn.example.net",
            XRAY_SNI="example.org",
            XRAY_VERSION="v26.11.9",
        )
        result = subprocess.run(
            [self.bash, "--noprofile", "--norc", shell_path(installer), "--deploy"],
            env=env, stdin=subprocess.DEVNULL, text=True, encoding="utf-8",
            capture_output=True, timeout=25,
        )
        self.assertNotIn("UNEXPECTED_", result.stderr, result.stderr)
        log = directory / "docker-calls"
        calls = [
            line.rstrip("\t").split("\t")
            for line in log.read_text(encoding="utf-8").splitlines()
        ] if log.exists() else []
        return result, calls

    def require_jq(self):
        if not self.has_jq:
            self.skipTest("Real jq is required; install jq or set JQ_BIN")

    def require_openssl(self):
        if not self.has_openssl:
            self.skipTest("OpenSSL with X25519 support is required")

    def test_existing_config_is_never_treated_as_fresh_install(self):
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, _):
                self.run_shell(name, directory, 'XRAY_BIN="$TEST_ROOT/missing"; is_xray_installed')

    def test_fresh_install_refuses_to_overwrite_existing_configuration(self):
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, _):
                before = (directory / "config.json").read_bytes()
                self.run_shell(name, directory, "if new_install; then exit 1; fi")
                self.assertEqual((directory / "config.json").read_bytes(), before)

    def test_initial_validation_failure_does_not_publish_configuration_or_keys(self):
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, _):
                (directory / "config.json").unlink()
                (directory / "public.key").write_text("previous-cache\n", encoding="utf-8")
                address_before = (directory / "server.addr").read_bytes()
                body = f'''
install() {{ [[ "$1" == -d && -d "$4" ]]; }}
install_deps() {{ :; }}
install_xray_binary() {{ :; }}
enable_bbr() {{ :; }}
check_sni_target() {{ :; }}
ensure_xray_user() {{ :; }}
setup_log_rotation() {{ echo UNEXPECTED_LOGROTATE >&2; return 99; }}
detect_public_ip() {{ printf '198.51.100.42\\n'; }}
generate_uuid() {{ printf '{FIRST_UUID}\\n'; }}
generate_short_id() {{ printf 'aabbccdd\\n'; }}
fake_xray() {{ printf 'PrivateKey: {PRIVATE_KEY}\\nPassword: {PUBLIC_KEY}\\n'; }}
XRAY_BIN=fake_xray
validate_config() {{ cp -- "$1" "$TEST_ROOT/rejected-candidate.json"; return 1; }}
if new_install <<'INPUT'

example.org
2
1

INPUT
then exit 1; fi
'''
                self.run_shell(name, directory, body)
                self.assertFalse((directory / "config.json").exists())
                self.assertEqual((directory / "server.addr").read_bytes(), address_before)
                self.assertEqual((directory / "public.key").read_text().strip(), "previous-cache")
                candidate = json.loads((directory / "rejected-candidate.json").read_text())
                self.assertEqual(candidate["inbounds"][0]["streamSettings"]["realitySettings"]["privateKey"], PRIVATE_KEY)
                self.assertFalse(list(directory.glob(".config.*")), "rejected temporary config was left behind")

    def test_real_xray_accepts_generated_tcp_and_xhttp_configs(self):
        if not self.env.get("XRAY_TEST_BIN"):
            self.skipTest("Set XRAY_TEST_BIN to also check generated configs with Xray")
        self.require_jq()
        self.require_openssl()
        for name in SCRIPTS:
            for option, transport in (("1", "tcp"), ("2", "xhttp")):
                with self.subTest(script=name, transport=transport), self.fixture() as (directory, _):
                    (directory / "config.json").unlink()
                    body = f'''
XRAY_BIN="$XRAY_TEST_BIN"
install() {{ [[ "$1" == -d && -d "$4" ]]; }}
install_deps() {{ :; }}
install_xray_binary() {{ :; }}
enable_bbr() {{ :; }}
check_sni_target() {{ :; }}
ensure_xray_user() {{ :; }}
write_service() {{ :; }}
systemctl() {{ :; }}
can_restart_xray() {{ :; }}
restart_xray() {{ validate_config; }}
setup_log_rotation() {{ :; }}
setup_autostart() {{ :; }}
autostart_status() {{ printf 'test\\n'; }}
xray_pid() {{ :; }}
detect_public_ip() {{ printf '198.51.100.42\\n'; }}
generate_uuid() {{ printf '{FIRST_UUID}\\n'; }}
new_install <<'INPUT'

example.org
2
{option}

INPUT
cp -- "$CONFIG" "$TEST_ROOT/.config.edit"
validate_config "$TEST_ROOT/.config.edit"
printf '{{broken' > "$TEST_ROOT/.config.edit"
if validate_config "$TEST_ROOT/.config.edit"; then exit 1; fi
'''
                    result = self.run_shell(name, directory, body)
                    config = json.loads((directory / "config.json").read_text())
                    self.assertEqual(config["inbounds"][0]["streamSettings"]["network"], transport)
                    self.assertIn(f"vless://{FIRST_UUID}@198.51.100.42:443?", result.stdout)

    def test_official_sha2_256_digest_accepts_matching_archive(self):
        content = b"local Xray archive fixture\n"
        digest = hashlib.sha256(content).hexdigest()
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, _):
                (directory / "archive.zip").write_bytes(content)
                (directory / "archive.zip.dgst").write_text(
                    "SHA2-512= ignored-by-this-check\n" + f"SHA2-256= {digest.upper()}\n",
                    encoding="utf-8",
                )
                self.run_shell(name, directory, 'verify_xray_checksum "$TEST_ROOT/archive.zip" "$TEST_ROOT/archive.zip.dgst"')

    def test_digest_mismatch_rejects_archive(self):
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, _):
                (directory / "archive.zip").write_bytes(b"modified archive")
                (directory / "archive.zip.dgst").write_text("SHA2-256= " + "0" * 64 + "\n", encoding="utf-8")
                self.run_shell(name, directory, r'''
if verify_xray_checksum "$TEST_ROOT/archive.zip" "$TEST_ROOT/archive.zip.dgst"; then exit 1; fi
''')

    def test_invalid_digest_format_rejects_archive(self):
        for name in SCRIPTS:
            for invalid in ("0" * 64, "SHA2-256=1234", "SHA2-256=" + "g" * 64):
                with self.subTest(script=name, digest=invalid), self.fixture() as (directory, _):
                    (directory / "archive.zip").write_bytes(b"local fixture")
                    (directory / "archive.zip.dgst").write_text(invalid + "\n", encoding="utf-8")
                    self.run_shell(name, directory, r'''
if verify_xray_checksum "$TEST_ROOT/archive.zip" "$TEST_ROOT/archive.zip.dgst"; then exit 1; fi
''')

    def test_public_lookup_failure_does_not_return_a_lan_address(self):
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, _):
                result = self.run_shell(name, directory, r'''
curl() { return 7; }
hostname() { echo UNEXPECTED_HOSTNAME >&2; printf '172.17.0.2\n'; }
address="$(detect_public_ip)"
[[ -z "$address" ]]
''')
                self.assertEqual(result.stdout, "")

    def test_missing_systemd_unit_is_repaired_without_rotating_credentials(self):
        with self.fixture() as (directory, _):
            before = (directory / "config.json").read_bytes()
            self.run_shell("xray-install.sh", directory, r'''
ensure_xray_user() { :; }
ensure_xray_autostart() { :; }
effective_xray_service() {
    if [[ -f "$SERVICE_FILE" ]]; then echo managed; else echo missing; fi
}
systemctl() { printf '%s\n' "$*" >> "$TEST_ROOT/service-events"; }
prepare_existing_install
''')
            self.assertTrue((directory / "xray.service").is_file())
            self.assertEqual((directory / "config.json").read_bytes(), before)
            self.assertIn("daemon-reload", (directory / "service-events").read_text())

    def test_native_preflight_rejects_a_foreign_effective_execstart(self):
        with self.fixture() as (directory, _):
            service = directory / "xray.service"
            service.write_text("[Service]\n", encoding="utf-8")
            (directory / "config.json").unlink()
            binary_before = (directory / "xray-stub").read_bytes()
            self.run_shell("xray-install.sh", directory, r'''
systemctl() {
    printf '%s\n' 'LoadState=loaded' "FragmentPath=$SERVICE_FILE" \
        "Description=$SERVICE_DESCRIPTION" \
        "ExecStart={ path=$XRAY_BIN ; argv[]=$XRAY_BIN run -config /usr/local/etc/xray/config.json ; ignore_errors=no ; }" \
        "DropInPaths=$SERVICE_FILE.d/10-donot_touch_single_conf.conf"
}
if check_install_ownership; then exit 1; fi
''')
            self.assertEqual(service.read_text(), "[Service]\n")
            self.assertEqual((directory / "xray-stub").read_bytes(), binary_before)
            self.assertFalse((directory / "config.json").exists())

    def test_native_preflight_accepts_the_legacy_managed_unit(self):
        with self.fixture() as (directory, _):
            (directory / "xray.service").touch()
            self.run_shell("xray-install.sh", directory, r'''
systemctl() {
    printf '%s\n' 'LoadState=loaded' "FragmentPath=$SERVICE_FILE" \
        "Description=$SERVICE_DESCRIPTION" \
        "ExecStart={ path=$XRAY_BIN ; argv[]=$XRAY_BIN run -config $CONFIG ; ignore_errors=no ; }" \
        'DropInPaths='
}
check_install_ownership
''')

    def test_bbr_failure_does_not_save_a_drop_in_and_restores_runtime_settings(self):
        with self.fixture() as (directory, _):
            self.run_shell("xray-install.sh", directory, r'''
BBR_CONF="$TEST_ROOT/99-xray-bbr.conf"
printf 'cubic\n' > "$TEST_ROOT/congestion"
sysctl() {
    case "$*" in
        '-n net.ipv4.tcp_congestion_control') cat "$TEST_ROOT/congestion" ;;
        '-n net.core.default_qdisc') printf 'fq_codel\n' ;;
        '-w net.ipv4.tcp_congestion_control=cubic') printf 'cubic\n' > "$TEST_ROOT/congestion" ;;
        "-p $BBR_CONF."*)
            : > "$TEST_ROOT/bbr-attempted"
            printf 'bbr\n' > "$TEST_ROOT/congestion"
            return 1
            ;;
        *) return 2 ;;
    esac
}
enable_bbr
''')
            self.assertTrue((directory / "bbr-attempted").is_file())
            self.assertEqual((directory / "congestion").read_text(), "cubic\n")
            self.assertFalse(list(directory.glob("99-xray-bbr.conf*")))

    def test_failed_binary_recovery_does_not_replace_existing_config(self):
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, _):
                before = (directory / "config.json").read_bytes()
                self.run_shell(name, directory, r'''
XRAY_BIN="$TEST_ROOT/missing-binary"
effective_xray_service() { echo missing; }
install_deps() { :; }
install_xray_binary() { return 1; }
if prepare_existing_install; then exit 1; fi
''')
                self.assertEqual((directory / "config.json").read_bytes(), before)

    def test_saved_domain_survives_a_different_egress_ip(self):
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, _):
                result = self.run_shell(name, directory, r'''
detect_public_ip() { printf '198.51.100.42\n'; }
get_server_address
''')
                self.assertEqual(result.stdout.strip(), "vpn.example.net")

    def test_public_key_is_recovered_from_active_private_key(self):
        self.require_jq()
        self.require_openssl()
        for name in SCRIPTS:
            for stale_cache in (False, True):
                with self.subTest(script=name, stale_cache=stale_cache), self.fixture() as (directory, _):
                    if stale_cache:
                        (directory / "public.key").write_text("stale-key\n", encoding="utf-8")
                    before = (directory / "config.json").read_bytes()
                    result = self.run_shell(name, directory, "get_public_key")
                    self.assertEqual(result.stdout.strip(), PUBLIC_KEY)
                    self.assertEqual((directory / "public.key").read_text().strip(), PUBLIC_KEY)
                    self.assertEqual((directory / "config.json").read_bytes(), before)

    def test_key_failure_does_not_add_a_user(self):
        self.require_jq()
        self.require_openssl()
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, config):
                config["inbounds"][0]["streamSettings"]["realitySettings"]["privateKey"] = "invalid-private-key"
                (directory / "config.json").write_text(json.dumps(config), encoding="utf-8")
                before = (directory / "config.json").read_bytes()
                result = self.run_shell(name, directory, r'''
restart_xray() { echo UNEXPECTED_RESTART >&2; return 99; }
add_client
''', success=False)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual((directory / "config.json").read_bytes(), before)
                self.assertNotIn(PRIVATE_KEY, result.stdout + result.stderr)
                self.assertNotIn("invalid-private-key", result.stdout + result.stderr)

    def test_private_key_never_appears_in_external_command_arguments(self):
        self.require_jq()
        self.require_openssl()
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, _):
                result = self.run_shell(name, directory, r'''
openssl() {
    printf '%s\n' "$@" >> "$TEST_ROOT/openssl-arguments"
    command openssl "$@"
}
get_public_key
''')
                self.assertEqual(result.stdout.strip(), PUBLIC_KEY)
                arguments = (directory / "openssl-arguments").read_text()
                self.assertIn("pkey", arguments)
                self.assertNotIn(PRIVATE_KEY, arguments)
                self.assertNotIn(base64.urlsafe_b64decode(PRIVATE_KEY + "=").hex(), arguments)

    def test_successful_addition_preserves_existing_clients_and_uses_active_key(self):
        self.require_jq()
        self.require_openssl()
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, config):
                (directory / "public.key").write_text("outdated-cache\n", encoding="utf-8")
                self.run_shell(name, directory, r'''
validate_config() { jq -e . "${1:-$CONFIG}" >/dev/null; }
can_restart_xray() { return 0; }
restart_xray() { printf 'restart\n' >> "$TEST_ROOT/events"; }
openssl() {
    [[ "${1:-}" != pkey ]] || printf 'derive\n' >> "$TEST_ROOT/events"
    command openssl "$@"
}
generate_uuid() { printf '00000000-0000-4000-8000-000000000003\n'; }
generate_short_id() { printf '55667788\n'; }
show_connection_info() { printf '%s\n' "$@" > "$TEST_ROOT/connection-arguments"; }
add_client
''')
                after = json.loads((directory / "config.json").read_text())
                clients = after["inbounds"][0]["settings"]["clients"]
                self.assertEqual(clients[:2], config["inbounds"][0]["settings"]["clients"])
                self.assertEqual(clients[2]["id"], "00000000-0000-4000-8000-000000000003")
                self.assertEqual((directory / "connection-arguments").read_text().splitlines()[1:3], ["vpn.example.net", PUBLIC_KEY])
                self.assertEqual((directory / "events").read_text().splitlines(), ["derive", "restart"])

    def test_failed_restart_restores_previous_configuration(self):
        self.require_jq()
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, config):
                before = (directory / "config.json").read_bytes()
                config["marker"] = "new"
                (directory / "pending.json").write_text(json.dumps(config), encoding="utf-8")
                self.run_shell(name, directory, r'''
validate_config() { jq -e . "${1:-$CONFIG}" >/dev/null; }
can_restart_xray() { return 0; }
restart_xray() {
    marker="$(jq -r .marker "$CONFIG")"
    printf '%s\n' "$marker" >> "$TEST_ROOT/restarts"
    [[ "$marker" == old ]]
}
if apply_config_change "$TEST_ROOT/pending.json"; then
    echo 'failed update was reported as successful' >&2
    exit 1
fi
''')
                self.assertEqual((directory / "config.json").read_bytes(), before)
                self.assertEqual((directory / "config.json.bak").read_bytes(), before)
                self.assertEqual((directory / "restarts").read_text().splitlines(), ["new", "old"])

    def test_invalid_configuration_never_restarts_or_replaces(self):
        self.require_jq()
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, _):
                before = (directory / "config.json").read_bytes()
                (directory / "pending.json").write_text("{broken", encoding="utf-8")
                self.run_shell(name, directory, r'''
validate_config() { jq -e . "${1:-$CONFIG}" >/dev/null 2>&1; }
restart_xray() { echo UNEXPECTED_RESTART >&2; return 99; }
if apply_config_change "$TEST_ROOT/pending.json"; then exit 1; fi
''')
                self.assertEqual((directory / "config.json").read_bytes(), before)

    def test_restart_preflight_failure_keeps_configuration_unchanged(self):
        self.require_jq()
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, config):
                before = (directory / "config.json").read_bytes()
                config["marker"] = "new"
                (directory / "pending.json").write_text(json.dumps(config), encoding="utf-8")
                self.run_shell(name, directory, r'''
validate_config() { return 0; }
can_restart_xray() { return 1; }
restart_xray() { echo UNEXPECTED_RESTART >&2; return 99; }
if apply_config_change "$TEST_ROOT/pending.json"; then exit 1; fi
''')
                self.assertEqual((directory / "config.json").read_bytes(), before)
                self.assertFalse((directory / "config.json.bak").exists())

    def test_configuration_permissions_are_restricted_before_atomic_replace(self):
        if os.name == "nt":
            self.skipTest("POSIX permission assertions require Linux")
        self.require_jq()
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, config):
                config["marker"] = "new"
                candidate = directory / "pending.json"
                candidate.write_text(json.dumps(config), encoding="utf-8")
                candidate.chmod(0o666)
                self.run_shell(name, directory, r'''
validate_config() { return 0; }
can_restart_xray() { return 0; }
restart_xray() { return 0; }
mv() {
    if [[ "${@: -1}" == "$CONFIG" ]]; then
        [[ "$(stat -c %a "${@: -2:1}")" == 640 ]] || return 1
        printf 'restricted-before-rename\n' > "$TEST_ROOT/permissions-checked"
    fi
    command mv "$@"
}
apply_config_change "$TEST_ROOT/pending.json"
''')
                self.assertTrue((directory / "permissions-checked").exists())
                self.assertEqual((directory / "config.json").stat().st_mode & 0o777, 0o640)
                self.assertEqual((directory / "config.json.bak").stat().st_mode & 0o777, 0o600)

    def test_removing_uuid_preserves_shared_short_ids(self):
        self.require_jq()
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, config):
                self.run_shell(name, directory, r'''
validate_config() { jq -e . "${1:-$CONFIG}" >/dev/null; }
restart_xray() { return 0; }
can_restart_xray() { return 0; }
remove_client <<'INPUT'
1
y
INPUT
''')
                after = json.loads((directory / "config.json").read_text())
                self.assertEqual([client["id"] for client in after["inbounds"][0]["settings"]["clients"]], [SECOND_UUID])
                self.assertEqual(after["inbounds"][0]["streamSettings"]["realitySettings"]["shortIds"], config["inbounds"][0]["streamSettings"]["realitySettings"]["shortIds"])

    def test_removal_selection_with_leading_zero_is_decimal(self):
        self.require_jq()
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture(count=9) as (directory, _):
                self.run_shell(name, directory, r'''
validate_config() { jq -e . "${1:-$CONFIG}" >/dev/null; }
restart_xray() { return 0; }
can_restart_xray() { return 0; }
remove_client <<'INPUT'
08
y
INPUT
''')
                after = json.loads((directory / "config.json").read_text())
                clients = after["inbounds"][0]["settings"]["clients"]
                self.assertEqual(len(clients), 8)
                self.assertNotIn("00000000-0000-4000-8000-000000000008", [client["id"] for client in clients])

    def test_address_change_is_explicit_and_ipv6_uri_is_bracketed(self):
        self.require_jq()
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, _):
                result = self.run_shell(name, directory, f'''
change_server_address <<'INPUT'
2001:db8::123
y
INPUT
show_client_routing() {{ :; }}
show_connection_info '{FIRST_UUID}' "$(get_server_address)" '{PUBLIC_KEY}' 'aabbccdd' 'example.org'
''')
                self.assertEqual((directory / "server.addr").read_text().strip(), "2001:db8::123")
                self.assertIn(f"vless://{FIRST_UUID}@[2001:db8::123]:443?", result.stdout)

    def test_existing_client_link_uses_public_port_without_restarting(self):
        self.require_jq()
        self.require_openssl()
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, config):
                config["inbounds"][0]["port"] = 9443
                (directory / "config.json").write_text(json.dumps(config), encoding="utf-8")
                before = (directory / "config.json").read_bytes()
                result = self.run_shell(name, directory, r'''
restart_xray() { echo UNEXPECTED_RESTART >&2; return 99; }
show_client_routing() { :; }
export_client_link <<<'2'
change_server_port <<'INPUT'
8443
y
INPUT
export_client_link <<<'2'
''')
                self.assertEqual((directory / "config.json").read_bytes(), before)
                self.assertEqual((directory / "server.port").read_text().strip(), "8443")
                links = [
                    urlsplit(line) for line in result.stdout.splitlines() if line.startswith("vless://")
                ]
                self.assertEqual([link.port for link in links], [9443, 8443])
                for link in links:
                    self.assertEqual(link.username, SECOND_UUID)
                    self.assertEqual(link.hostname, "vpn.example.net")
                    query = parse_qs(link.query)
                    self.assertEqual(query["pbk"], [PUBLIC_KEY])
                    self.assertEqual(query["sid"], ["aabbccdd"])
                    self.assertEqual(query["flow"], ["xtls-rprx-vision"])

    def test_invalid_public_ports_leave_existing_public_port_unchanged(self):
        self.require_jq()
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, _):
                (directory / "server.port").write_bytes(b"8443\n")
                self.run_shell(name, directory, r'''
for invalid in 0 65536 443abc 18446744073709552059; do
    if change_server_port <<< "$invalid"; then
        echo "invalid port accepted: $invalid" >&2
        exit 1
    fi
done
''')
                self.assertEqual((directory / "server.port").read_bytes(), b"8443\n")

    def test_failed_routing_export_does_not_write_empty_links(self):
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, _):
                result = self.run_shell(name, directory, r'''
jq() { return 42; }
show_client_routing || printf 'export failed\n'
''')
                self.assertIn("export failed", result.stdout)
                self.assertNotIn("Profile saved", result.stdout)
                self.assertFalse(list(directory.glob("ru-direct-*.txt")))

    def test_invalid_addresses_are_rejected(self):
        for name in SCRIPTS:
            with self.subTest(script=name), self.fixture() as (directory, _):
                self.run_shell(name, directory, r'''
for address in 'https://vpn.example.net' 'vpn.example.net:443' '999.1.2.3' 'space name' 'host/path'; do
    if validate_server_address "$address"; then
        printf 'invalid address accepted: %s\n' "$address" >&2
        exit 1
    fi
done
''')

    def test_docker_invalid_config_is_checked_before_stop(self):
        with self.fixture() as (directory, _):
            self.run_shell("xray-install-docker.sh", directory, r'''
validate_config() { printf 'validate\n' >> "$TEST_ROOT/order"; return 1; }
stop_xray() { printf 'stop\n' >> "$TEST_ROOT/order"; }
start_xray() { printf 'start\n' >> "$TEST_ROOT/order"; }
if restart_xray; then exit 1; fi
''')
            self.assertEqual((directory / "order").read_text().splitlines(), ["validate"])

    def test_docker_deploy_builds_from_the_script_and_publishes_the_external_port(self):
        with self.fixture() as (directory, _):
            result, calls = self.run_docker_deploy(directory, "fresh")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(
                (directory / "built-installer.sh").read_bytes(),
                (ROOT / "xray-install-docker.sh").read_bytes(),
            )
            dockerfile = (directory / "built-dockerfile").read_text(encoding="utf-8")
            self.assertIn("/usr/local/sbin/xray-install-docker --prepare", dockerfile)
            self.assertIn('ENTRYPOINT ["/usr/local/bin/xray-entrypoint"]', dockerfile)
            label = "io.github.1517mb.xray-installer=test-xray"
            build = next(call for call in calls if call[0] == "build")
            self.assertIn(label, build)
            volume = next(call for call in calls if call[:2] == ["volume", "create"])
            self.assertIn(label, volume)
            self.assertIn("test-xray-config", volume)
            configure = next(call for call in calls if call[0] == "run")
            self.assertIn("--configure", configure)
            self.assertIn("XRAY_DOCKER_PORT=8443", configure)
            self.assertIn("XRAY_SERVER_ADDRESS=vpn.example.net", configure)
            self.assertIn("XRAY_SNI=example.org", configure)
            runtime = next(call for call in calls if call[:2] == ["container", "create"])
            self.assertIn(label, runtime)
            self.assertIn("8443:443/tcp", runtime)
            self.assertIn("unless-stopped", runtime)
            self.assertIn("test-xray-local:v26.11.9", runtime)
            self.assertIn(["container", "start", "created-container"], calls)

    def test_docker_deploy_restarts_its_stopped_container_without_reconfiguring(self):
        with self.fixture() as (directory, _):
            result, calls = self.run_docker_deploy(directory, "stopped")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(["container", "start", "test-xray"], calls)
            self.assertFalse(any(call[0] in {"build", "run", "volume"} for call in calls))
            self.assertFalse(any(call[:2] == ["container", "create"] for call in calls))

    def test_docker_deploy_refuses_foreign_resources(self):
        for scenario in ("foreign-container", "foreign-volume", "foreign-image"):
            with self.subTest(scenario=scenario), self.fixture() as (directory, _):
                result, calls = self.run_docker_deploy(directory, scenario)
                self.assertNotEqual(result.returncode, 0)
                resource = scenario.removeprefix("foreign-")
                self.assertTrue(any(call[:2] == [resource, "inspect"] for call in calls))
                self.assertTrue(all(call[0] == "info" or call[1] == "inspect" for call in calls))

    def test_docker_deploy_keeps_the_volume_when_configuration_fails(self):
        with self.fixture() as (directory, _):
            result, calls = self.run_docker_deploy(directory, "configure-fails")
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((directory / "volume-created").exists())
            self.assertTrue(any("--configure" in call for call in calls))
            self.assertFalse(any(call[1] in {"rm", "start"} for call in calls))
            self.assertFalse(any(call[:2] == ["container", "create"] for call in calls))

    def test_docker_deploy_does_not_install_when_existing_engine_is_unavailable(self):
        with self.fixture() as (directory, _):
            result, calls = self.run_docker_deploy(directory, "engine-unavailable")
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(calls)
            self.assertTrue(all(call[0] == "info" for call in calls))

    def test_missing_docker_installation_requires_an_explicit_yes(self):
        for answer in ("", "n"):
            with self.subTest(answer=answer), self.fixture() as (directory, _):
                body = DOCKER_INSTALL_MOCK + f'\ninstall_missing_docker <<< "{answer}"'
                result = self.run_shell("xray-install-docker.sh", directory, body, success=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((directory / "docker-download-args").exists())
                self.assertFalse((directory / "docker-install-args").exists())

    def test_missing_docker_runs_official_stable_installer_after_complete_download(self):
        for download_status in (0, 22):
            with self.subTest(download_status=download_status), self.fixture() as (directory, _):
                body = (
                    f'DOWNLOAD_STATUS={download_status}\n'
                    + DOCKER_INSTALL_MOCK
                    + '\ninstall_missing_docker <<< "y"'
                )
                result = self.run_shell(
                    "xray-install-docker.sh", directory, body, success=download_status == 0,
                )
                download_args = (directory / "docker-download-args").read_text().splitlines()
                self.assertTrue(
                    {"https://get.docker.com", "https://get.docker.com/"} & set(download_args),
                )
                install_args = directory / "docker-install-args"
                if download_status == 0:
                    self.assertEqual(install_args.read_text().splitlines(), ["--channel", "stable"])
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(install_args.exists())

    def test_docker_deployment_continues_after_bootstrap_starts_the_engine(self):
        with self.fixture() as (directory, _):
            body = DOCKER_INSTALL_MOCK + r'''
DOWNLOAD_STATUS=0
command() {
    if [[ "$*" == "-v docker" && ! -f "$TEST_ROOT/docker-install-args" ]]; then return 1; fi
    builtin command "$@"
}
docker() {
    if [[ "$*" == "--host unix:///var/run/docker.sock info --format {{.OSType}}" &&
          -f "$TEST_ROOT/docker-service-started" ]]; then
        printf 'linux\n'
    else
        return 1
    fi
}
systemctl() {
    [[ "$*" == "enable --now docker.service" ]] || { echo UNEXPECTED_SERVICE >&2; return 99; }
    : > "$TEST_ROOT/docker-service-started"
}
docker_cli=(docker)
ensure_deployment_docker docker_cli <<< "yes"
"${docker_cli[@]}" info --format '{{.OSType}}'
'''
            result = self.run_shell("xray-install-docker.sh", directory, body)
            self.assertTrue((directory / "docker-service-started").exists())
            self.assertIn("linux", result.stdout.splitlines())

    def test_docker_deployment_does_not_bootstrap_for_an_explicit_remote_endpoint(self):
        with self.fixture() as (directory, _):
            body = DOCKER_INSTALL_MOCK + r'''
DOWNLOAD_STATUS=0
command() {
    if [[ "$*" == "-v docker" ]]; then return 1; fi
    builtin command "$@"
}
export DOCKER_HOST=tcp://docker.example.net:2376
docker_cli=(docker)
ensure_deployment_docker docker_cli <<< "yes"
'''
            result = self.run_shell("xray-install-docker.sh", directory, body, success=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((directory / "docker-download-args").exists())

    def test_docker_unattended_setup_checks_sni_and_generates_the_client_link(self):
        self.require_jq()
        cases = (("configure", "2", 8443), ("configure", "1.1", 8443), ("start", "2", 443))
        for mode, http_version, port in cases:
            with self.subTest(mode=mode, http_version=http_version), self.fixture() as (directory, _):
                (directory / "config.json").unlink()
                body = f'''
XRAY_SERVER_ADDRESS=vpn.example.net
XRAY_SNI=example.org
XRAY_DOCKER_PORT=8443
ENTRYPOINT_BIN="$XRAY_BIN"
install() {{ [[ "$1" == -d && -d "$4" ]]; }}
install_deps() {{ [[ "{mode}" == start ]]; }}
curl() {{ printf '{http_version} 200 '; }}
detect_public_ip() {{ echo UNEXPECTED_AUTODETECT >&2; return 99; }}
restart_xray() {{ [[ "{mode}" == start ]]; }}
setup_log_rotation() {{ :; }}
setup_autostart() {{ :; }}
autostart_status() {{ echo fixture; }}
xray_pid() {{ echo 123; }}
generate_uuid() {{ printf '{FIRST_UUID}\\n'; }}
generate_short_id() {{ printf 'aabbccdd\\n'; }}
new_install {mode} </dev/null
'''
                result = self.run_shell(
                    "xray-install-docker.sh", directory, body, success=http_version == "2",
                )
                if http_version == "2":
                    self.assertIn(f"vless://{FIRST_UUID}@vpn.example.net:{port}?", result.stdout)
                    if mode == "configure":
                        self.assertEqual((directory / "server.port").read_text().strip(), str(port))
                    config = json.loads((directory / "config.json").read_text())
                    self.assertEqual(config["dns"]["servers"], ["8.8.8.8", "8.8.4.4"])
                    self.assertEqual(config["inbounds"][0]["streamSettings"]["network"], "tcp")
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("no HTTP/2 support", result.stderr)
                    self.assertFalse((directory / "config.json").exists())
                    self.assertFalse((directory / "server.port").exists())

    def test_docker_uninstall_keeps_unrelated_volume_files(self):
        with self.fixture() as (directory, _):
            owned_files = (
                "config.json.bak", "server.port", "public.key", "ru-direct.json",
                "ru-direct-incy.txt", "ru-direct-happ.txt", f"vless-{FIRST_UUID}.png",
                "xray.log", "xray.log.1", "xray.log.2.gz",
            )
            for name in (*owned_files, "unrelated.txt", "vless-custom.png"):
                (directory / name).touch()
            self.run_shell("xray-install-docker.sh", directory, r'''
AUTOSTART_BIN="$TEST_ROOT/xray-autostart"
ENTRYPOINT_BIN="$TEST_ROOT/xray-entrypoint"
OPENRC_LOCAL="$TEST_ROOT/xray.start"
RC_LOCAL="$TEST_ROOT/rc.local"
stop_xray() { :; }
crontab() { return 1; }
remove_xray <<<'y'
''')
            self.assertTrue((directory / "unrelated.txt").is_file())
            self.assertTrue((directory / "vless-custom.png").is_file())
            for name in (*owned_files, "xray-stub", "config.json", "server.addr"):
                self.assertFalse((directory / name).exists(), name)

    def test_docker_matches_only_exact_process_arguments(self):
        with self.fixture() as (directory, _):
            proc = directory / "proc"
            for pid, arguments in {
                "101": [shell_path(directory / "xray-stub"), "run", "-config", shell_path(directory / "config.json")],
                "102": [shell_path(directory / "xray-stub"), "run", "-config", shell_path(directory / "config.json") + ".backup"],
                "103": [shell_path(directory / "xray-stub"), "run", "-test", "-config", shell_path(directory / "config.json")],
            }.items():
                target = proc / pid
                target.mkdir(parents=True)
                (target / "cmdline").write_bytes(b"\0".join(argument.encode() for argument in arguments) + b"\0")
            result = self.run_shell("xray-install-docker.sh", directory, r'''
XRAY_PROC_ROOT="$TEST_ROOT/proc"
is_xray_pid 101
if is_xray_pid 102 || is_xray_pid 103; then exit 1; fi
xray_pids
''')
            self.assertEqual(result.stdout.strip(), "101")

    def write_process_stat(self, directory, pid, started, comm="xray"):
        target = directory / "proc" / str(pid)
        target.mkdir(parents=True, exist_ok=True)
        # The suffix starts at field 3; starttime is field 22 (index 19 here).
        fields = ["S"] + ["0"] * 18 + [str(started)] + ["0"] * 8
        (target / "stat").write_bytes((f"{pid} ({comm}) " + " ".join(fields) + "\n").encode())

    def test_proc_start_time_handles_spaces_and_parentheses_in_process_name(self):
        with self.fixture() as (directory, _):
            self.write_process_stat(directory, 101, 123456, "entry ) point with spaces )")
            result = self.run_shell("xray-install-docker.sh", directory, r'''
XRAY_PROC_ROOT="$TEST_ROOT/proc"
process_start_time 101
''')
            self.assertEqual(result.stdout.strip(), "123456")

    def test_live_entrypoint_claim_is_preserved_and_blocks_background_start(self):
        with self.fixture() as (directory, _):
            self.write_process_stat(directory, 101, 123456)
            self.run_shell("xray-install-docker.sh", directory, r'''
XRAY_PROC_ROOT="$TEST_ROOT/proc"
write_entrypoint_claim 101
has_live_entrypoint_claim
validate_config() { echo UNEXPECTED_VALIDATION >&2; return 99; }
if start_xray; then exit 1; fi
if can_restart_xray; then exit 1; fi
''')
            self.assertEqual((directory / "installer.lock.entrypoint").read_text().strip(), "101 123456")
            self.assertFalse((directory / "launched").exists())

    def test_reused_pid_does_not_keep_a_stale_entrypoint_claim(self):
        with self.fixture() as (directory, _):
            self.write_process_stat(directory, 101, 999999)
            (directory / "installer.lock.entrypoint").write_bytes(b"101 123456\n")
            self.run_shell("xray-install-docker.sh", directory, r'''
XRAY_PROC_ROOT="$TEST_ROOT/proc"
if has_live_entrypoint_claim; then exit 1; else [[ "$?" == 1 ]]; fi
[[ ! -e "${LOCK_FILE}.entrypoint" ]]
can_restart_xray
''')
            self.assertFalse((directory / "installer.lock.entrypoint").exists())

    def test_failed_stale_claim_cleanup_blocks_start(self):
        with self.fixture() as (directory, _):
            self.write_process_stat(directory, 101, 999999)
            (directory / "installer.lock.entrypoint").write_bytes(b"101 123456\n")
            self.run_shell("xray-install-docker.sh", directory, r'''
XRAY_PROC_ROOT="$TEST_ROOT/proc"
rm() { return 1; }
if has_live_entrypoint_claim; then exit 1; else [[ "$?" == 2 ]]; fi
if start_xray; then exit 1; fi
''')
            self.assertFalse((directory / "launched").exists())

    def test_log_rotation_configuration_is_generated_for_background_log(self):
        with self.fixture() as (directory, _):
            # Git Bash install -d may try to change Windows ancestor permissions.
            (directory / "logrotate.d").mkdir()
            body = "setup_log_rotation"
            if os.name == "nt":
                body = 'install() { [[ "$1" == -d && -d "${@: -1}" ]]; }\n' + body
            self.run_shell("xray-install-docker.sh", directory, body)
            configuration = (directory / "logrotate.d" / "xray-installer").read_text()
            self.assertIn(shell_path(directory / "xray.log"), configuration)
            self.assertIn("maxsize 10M", configuration)
            self.assertIn("copytruncate", configuration)

    def test_foreground_launcher_executes_xray_without_backgrounding(self):
        with self.fixture() as (directory, _):
            result = self.run_shell("xray-install-docker.sh", directory, r'''
AUTOSTART_BIN="$TEST_ROOT/xray-autostart"
ENTRYPOINT_BIN="$TEST_ROOT/xray-entrypoint"
write_autostart_launcher
bash -n "$ENTRYPOINT_BIN"
''')
            self.assertEqual(result.returncode, 0)
            launcher = (directory / "xray-entrypoint").read_text(encoding="utf-8")
            self.assertRegex(launcher, r'(?m)^exec\s+.*run.*-config')
            self.assertNotIn("nohup", launcher)

    def test_failed_cron_installation_is_not_reported_as_success(self):
        with self.fixture() as (directory, _):
            result = self.run_shell("xray-install-docker.sh", directory, r'''
AUTOSTART_BIN="$TEST_ROOT/xray-autostart"
ENTRYPOINT_BIN="$TEST_ROOT/xray-entrypoint"
OPENRC_LOCAL="$TEST_ROOT/xray.start"
autostart_mechanism() { printf 'none\n'; }
cron_running() { return 0; }
crontab() { return 1; }
if setup_autostart; then exit 1; fi
''')
            self.assertNotIn("Autostart: cron", result.stdout)

    def test_linux_foreground_launcher_claims_and_executes_in_same_process(self):
        if os.name == "nt" or not shutil.which("flock") or not Path("/proc/self/stat").exists():
            self.skipTest("Foreground process identity requires Linux/proc/flock")
        with self.fixture() as (directory, _):
            self.run_shell("xray-install-docker.sh", directory, r'''
AUTOSTART_BIN="$TEST_ROOT/xray-autostart"
ENTRYPOINT_BIN="$TEST_ROOT/xray-entrypoint"
write_autostart_launcher
''')
            env = self.env.copy()
            env["TEST_ROOT"] = shell_path(directory)
            process = subprocess.Popen(
                [self.bash, "--noprofile", "--norc", str(directory / "xray-entrypoint")],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                encoding="utf-8", env=env,
            )
            stdout, stderr = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, stdout + stderr)
            self.assertEqual((directory / "exec-pid").read_text().strip(), str(process.pid))
            claimed_pid, started = (directory / "installer.lock.entrypoint").read_text().split()
            self.assertEqual(claimed_pid, str(process.pid))
            self.assertTrue(started.isdigit())

    def test_simultaneous_installer_operations_are_rejected(self):
        if os.name == "nt" or not shutil.which("flock"):
            self.skipTest("Real flock contention requires Linux/util-linux")
        operations = [(name, "acquire_install_lock") for name in SCRIPTS]
        operations.append(("xray-install-docker.sh", "acquire_config_lock"))
        for name, lock in operations:
            with self.subTest(script=name, lock=lock), self.fixture() as (directory, _):
                env = self.env.copy()
                env["TEST_ROOT"] = shell_path(directory)
                holder = self.libraries[name] + r'''
CONFIG="$TEST_ROOT/config.json"
LOCK_FILE="$TEST_ROOT/installer.lock"
''' + lock + r'''
printf 'ready\n' > "$TEST_ROOT/lock-ready"
for ((attempt=0; attempt<300; attempt++)); do
    [[ ! -e "$TEST_ROOT/lock-release" ]] || exit 0
    sleep 0.1
done
exit 2
'''
                process = subprocess.Popen(
                    [self.bash, "--noprofile", "--norc"], stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                    encoding="utf-8", env=env,
                )
                try:
                    process.stdin.write(holder)
                    process.stdin.close()
                    deadline = time.monotonic() + 10
                    while not (directory / "lock-ready").exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue((directory / "lock-ready").exists(), "lock holder did not start")
                    contender = lock
                    if lock == "acquire_config_lock":
                        contender = 'LOCK_FILE="$TEST_ROOT/another-runtime.lock"\n' + lock
                    rejected = self.run_shell(name, directory, contender, success=False)
                    self.assertNotEqual(rejected.returncode, 0, rejected.stdout)
                finally:
                    (directory / "lock-release").touch()
                    process.wait(timeout=5)
                    process.stdout.close()
                    process.stderr.close()


if __name__ == "__main__":
    unittest.main()

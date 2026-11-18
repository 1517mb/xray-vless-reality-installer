"""Run the built image with an isolated Docker volume when XRAY_TEST_IMAGE is set."""

import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
from urllib.parse import parse_qs, urlsplit


IMAGE = os.environ.get("XRAY_TEST_IMAGE")
INSTALLER = "/usr/local/sbin/xray-install-docker"
SCRIPT = Path(__file__).resolve().parents[1] / "xray-install-docker.sh"


@unittest.skipUnless(IMAGE, "Set XRAY_TEST_IMAGE to exercise the Docker image and volume")
class DockerLifecycleTests(unittest.TestCase):
    def docker(self, *args, input=None, check=True):
        result = subprocess.run(
            ["docker", *args], input=input, capture_output=True, text=True, timeout=60,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def create_volume(self):
        self.volume = self.docker("volume", "create").stdout.strip()
        self.addCleanup(self.docker, "volume", "rm", self.volume)
        self.mount = f"type=volume,source={self.volume},target=/etc/xray"

    def run_installer(self, answers, *args):
        # Provide deterministic public-IP and SNI responses on a network-disabled
        # fixture. The installer and Xray otherwise run through their real entry points.
        return self.docker(
            "run", "--rm", "-i", "--network", "none", "--mount", self.mount,
            "--entrypoint", "/bin/bash", IMAGE, "-c",
            """
curl() {
    case "$*" in
        *api.ipify.org*|*ifconfig.me*) printf '198.51.100.42\\n' ;;
        *) printf '2 200 ' ;;
    esac
}
export -f curl
exec "$@"
""",
            "installer-test", INSTALLER, *args, input=answers,
        ).stdout

    def run_in_volume(self, body):
        return self.docker(
            "run", "--rm", "--network", "none", "--mount", self.mount,
            "--entrypoint", "/bin/bash", IMAGE, "-ec", body,
        ).stdout

    def start_container(self):
        container = self.docker(
            "run", "-d", "--init", "--network", "none", "--mount", self.mount, IMAGE,
        ).stdout.strip()
        self.addCleanup(self.docker, "rm", "-f", container, check=False)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            probe = self.docker(
                "exec", container, "bash", "-c", ": >/dev/tcp/127.0.0.1/443", check=False,
            )
            if probe.returncode == 0:
                return container
            time.sleep(0.25)
        logs = self.docker("logs", container)
        self.fail(logs.stdout + logs.stderr + probe.stderr)

    def assert_xhttp_link(self, output, port):
        links = [urlsplit(line) for line in output.splitlines() if line.startswith("vless://")]
        self.assertEqual(len(links), 1, "expected a single connection link")
        link = links[0]
        self.assertEqual(link.hostname, "vpn.example.net")
        self.assertEqual(link.port, port)
        self.assertEqual(parse_qs(link.query)["type"], ["xhttp"])
        return link.username

    def test_configure_start_recreate_and_remove(self):
        self.create_volume()
        self.run_in_volume("test ! -e /etc/xray/config.json")
        configured = self.run_installer("vpn.example.net\nexample.org\n2\n2\n\n", "--configure")
        uuid = self.assert_xhttp_link(configured, 443)
        self.assertRegex(uuid, r"^[0-9a-f-]{36}$")

        self.run_installer("9\n8443\ny\n")
        original = self.run_in_volume(
            "printf 'keep\\n' > /etc/xray/unrelated.txt; sha256sum /etc/xray/config.json"
        )
        first = self.start_container()
        first_export = self.docker("exec", "-i", first, INSTALLER, input="8\n1\n").stdout
        self.assertEqual(self.assert_xhttp_link(first_export, 8443), uuid)

        self.docker("stop", "--time", "5", first)
        self.docker("rm", first)
        recreated = self.start_container()
        recreated_export = self.docker("exec", "-i", recreated, INSTALLER, input="8\n1\n").stdout
        self.assertEqual(self.assert_xhttp_link(recreated_export, 8443), uuid)
        self.assertEqual(self.run_in_volume("sha256sum /etc/xray/config.json"), original)

        self.docker("stop", "--time", "5", recreated)
        self.docker("rm", recreated)
        self.run_installer("4\ny\n")
        remaining = self.run_in_volume("ls -A /etc/xray; cat /etc/xray/unrelated.txt")
        self.assertEqual(remaining.splitlines(), [".xray-installer.lock", "unrelated.txt", "keep"])

    def test_deploy_from_a_single_downloaded_file(self):
        name = f"xray-deploy-test-{secrets.token_hex(4)}"
        self.addCleanup(self.docker, "image", "rm", f"{name}-local:v26.11.9", check=False)
        self.addCleanup(self.docker, "volume", "rm", f"{name}-config", check=False)
        self.addCleanup(self.docker, "rm", "-f", name, check=False)
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            port = reserved.getsockname()[1]
        env = dict(
            os.environ, XRAY_DOCKER_NAME=name, XRAY_DOCKER_PORT=str(port),
            XRAY_SERVER_ADDRESS="vpn.example.net", XRAY_SNI="example.org",
            XRAY_VERSION="v26.11.9",
        )
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "xray-install-docker.sh"
            shutil.copyfile(SCRIPT, script)
            first_deployment = self.deploy(script, env)
            link, = [urlsplit(line) for line in first_deployment.splitlines() if line.startswith("vless://")]
            self.assertEqual(link.hostname, "vpn.example.net")
            self.assertEqual(link.port, port)
            self.assertEqual(parse_qs(link.query)["flow"], ["xtls-rprx-vision"])
            container_id = self.docker("inspect", "-f", "{{.Id}}", name).stdout
            before = self.docker("exec", name, "sha256sum", "/etc/xray/config.json").stdout

            self.docker("stop", "--time", "5", name)
            self.deploy(script, env)
            self.assertEqual(self.docker("inspect", "-f", "{{.Id}}", name).stdout, container_id)
            self.assertEqual(self.docker("exec", name, "sha256sum", "/etc/xray/config.json").stdout, before)

    def deploy(self, script, env):
        # Keep the real Docker workflow while avoiding a dependency on an
        # external SNI and binding the fixture port to loopback.
        body = r'''
docker() {
    if [[ "$1" == run && "${@: -1}" == --configure ]]; then
        shift
        command docker run --network none --env 'BASH_FUNC_curl%%=() { printf "2 200 "; }' "$@"
        return
    fi
    local -a options=()
    while (($#)); do
        if [[ "$1" == --publish || "$1" == -p ]]; then
            options+=("$1" "127.0.0.1:$2")
            shift 2
        else
            options+=("$1")
            shift
        fi
    done
    command docker "${options[@]}"
}
export -f docker
exec bash "$1" --deploy
'''
        result = subprocess.run(
            ["bash", "-c", body, "deploy-test", str(script)], cwd=script.parent, env=env,
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=300,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

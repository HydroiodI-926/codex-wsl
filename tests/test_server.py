import io
import json
import tarfile
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

from broker.codexbox.config import BrokerConfig
from broker.codexbox.server import BrokerApplication


def source_archive():
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        data = b"hello\n"
        info = tarfile.TarInfo("hello.txt")
        info.size = len(data)
        archive.addfile(info, io.BytesIO(data))
    return output.getvalue()


class BrokerServerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.token = "t" * 64
        token_file = root / "token"
        token_file.write_text(self.token, encoding="utf-8")
        config = BrokerConfig(root=root / "data", token_file=token_file, port=0)
        application = BrokerApplication(config)
        self.server = ThreadingHTTPServer(
            ("127.0.0.1", 0), application.handler_class()
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary.cleanup()

    def request(self, method, path, body=None, content_type="application/json"):
        if isinstance(body, dict):
            body = json.dumps(body).encode("utf-8")
        request = urllib.request.Request(
            self.base_url + path,
            method=method,
            data=body,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": content_type,
            },
        )
        return urllib.request.urlopen(request, timeout=5)

    def test_rejects_missing_token(self):
        request = urllib.request.Request(self.base_url + "/v1/health")
        with self.assertRaises(urllib.error.HTTPError) as context:
            urllib.request.urlopen(request, timeout=5)
        self.assertEqual(401, context.exception.code)

    def test_health_create_import_and_export(self):
        with self.request("GET", "/v1/health") as response:
            health = json.load(response)
        self.assertEqual("ok", health["status"])

        with self.request(
            "POST",
            "/v1/workspaces",
            {"mode": "isolated", "name": "server-test"},
        ) as response:
            workspace = json.load(response)
        workspace_id = workspace["workspace_id"]

        with self.request(
            "POST",
            f"/v1/workspaces/{workspace_id}/import",
            source_archive(),
            "application/gzip",
        ) as response:
            imported = json.load(response)
        self.assertIsNotNone(imported["baseline_tree"])

        with self.request(
            "GET", f"/v1/workspaces/{workspace_id}/changes"
        ) as response:
            bundle = response.read()
        with tarfile.open(fileobj=io.BytesIO(bundle), mode="r:gz") as archive:
            manifest = json.load(archive.extractfile("manifest.json"))
        self.assertEqual([], manifest["changes"])


if __name__ == "__main__":
    unittest.main()


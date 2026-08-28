import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from broker.codexbox.config import BrokerConfig
from broker.codexbox.executor import SandboxExecutor
from broker.codexbox.workspaces import WorkspaceStore


class SandboxExecutorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        token = root / "token"
        token.write_text("x" * 64, encoding="utf-8")
        self.config = BrokerConfig(root=root / "data", token_file=token)
        self.store = WorkspaceStore(self.config.root)
        self.workspace = self.store.create("persistent", "sample")
        self.executor = SandboxExecutor(self.config, self.store)

    def tearDown(self):
        self.temporary.cleanup()

    @patch("broker.codexbox.executor.shutil.which", return_value="/usr/bin/bwrap")
    def test_default_command_masks_sensitive_roots_and_network(self, _which):
        workspace = self.store.path(self.workspace.workspace_id)
        args = self.executor._build_command(workspace, ".", "pwd", False, {})
        rendered = "\n".join(args)
        self.assertIn("--unshare-net", args)
        self.assertIn("/mnt", args)
        self.assertIn("/run", args)
        self.assertIn("/etc/codexbox", args)
        self.assertIn("/srv/codexbox", args)
        self.assertIn("/workspace", args)
        git_index = args.index(str(workspace / ".git"))
        self.assertEqual("--ro-bind", args[git_index - 1])
        self.assertEqual("/workspace/.git", args[git_index + 1])
        self.assertEqual(["/bin/bash", "--noprofile", "--norc", "-lc", "pwd"], args[-5:])

    @patch("broker.codexbox.executor.shutil.which", return_value="/usr/bin/bwrap")
    def test_network_namespace_is_optional_only_in_command_builder(self, _which):
        workspace = self.store.path(self.workspace.workspace_id)
        args = self.executor._build_command(workspace, ".", "pwd", True, {})
        self.assertNotIn("--unshare-net", args)


if __name__ == "__main__":
    unittest.main()

import io
import json
import os
import tarfile
import tempfile
import unittest
from pathlib import Path

from broker.codexbox.workspaces import (
    WorkspaceError,
    WorkspaceStore,
    _normalize_link,
)


def make_archive(entries):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        for name, content in entries:
            info = tarfile.TarInfo(name)
            info.size = len(content)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(content))
    output.seek(0)
    return output


class WorkspaceStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.store = WorkspaceStore(self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def test_creates_both_modes(self):
        persistent = self.store.create("persistent", "sample")
        isolated = self.store.create("isolated", "sample")
        self.assertEqual("p-sample", persistent.workspace_id)
        self.assertRegex(isolated.workspace_id, r"^i-[a-f0-9]{16}$")
        self.assertEqual("persistent", persistent.mode)
        self.assertEqual("isolated", isolated.mode)

    def test_rejects_invalid_persistent_name(self):
        with self.assertRaises(WorkspaceError):
            self.store.create("persistent", "../escape")

    def test_import_rejects_path_traversal(self):
        workspace = self.store.create("isolated", "task")
        archive = make_archive([("../escape.txt", b"bad")])
        with self.assertRaises(WorkspaceError):
            self.store.import_archive(workspace.workspace_id, archive)
        self.assertFalse((self.root.parent / "escape.txt").exists())

    def test_import_rejects_excessive_expanded_size(self):
        store = WorkspaceStore(self.root / "small", max_extract_bytes=4)
        workspace = store.create("isolated", "task")
        archive = make_archive([("large.txt", b"12345")])
        with self.assertRaises(WorkspaceError):
            store.import_archive(workspace.workspace_id, archive)

    def test_import_rejects_git_metadata(self):
        workspace = self.store.create("isolated", "task")
        archive = make_archive([(".git/config", b"bad")])
        with self.assertRaises(WorkspaceError):
            self.store.import_archive(workspace.workspace_id, archive)

    def test_import_rejects_nested_git_metadata(self):
        workspace = self.store.create("isolated", "task")
        archive = make_archive([("vendor/example/.git/config", b"bad")])
        with self.assertRaises(WorkspaceError):
            self.store.import_archive(workspace.workspace_id, archive)

    def test_change_bundle_contains_patch_and_manifest(self):
        workspace = self.store.create("isolated", "task")
        archive = make_archive([("hello.txt", b"before\n")])
        self.store.import_archive(
            workspace.workspace_id, archive, source_sha256="abc123"
        )
        workspace_path = self.store.path(workspace.workspace_id)
        (workspace_path / "hello.txt").write_text("after\n", encoding="utf-8")
        (workspace_path / "new.txt").write_text("new\n", encoding="utf-8")

        bundle = self.store.change_bundle(workspace.workspace_id)
        with tarfile.open(fileobj=io.BytesIO(bundle), mode="r:gz") as result:
            patch = result.extractfile("change.patch").read()
            manifest = json.load(result.extractfile("manifest.json"))

        self.assertIn(b"hello.txt", patch)
        self.assertIn(b"new.txt", patch)
        self.assertEqual("abc123", manifest["source_sha256"])
        self.assertEqual(2, len(manifest["changes"]))

    def test_broker_only_deletes_isolated_workspaces(self):
        persistent = self.store.create("persistent", "sample")
        with self.assertRaises(WorkspaceError):
            self.store.delete_isolated(
                persistent.workspace_id, persistent.workspace_id
            )

        isolated = self.store.create("isolated", "sample")
        with self.assertRaises(WorkspaceError):
            self.store.delete_isolated(isolated.workspace_id, "wrong")
        self.store.delete_isolated(isolated.workspace_id, isolated.workspace_id)
        with self.assertRaises(WorkspaceError):
            self.store.get(isolated.workspace_id)

    def test_persistent_checkpoint_advances_baseline(self):
        workspace = self.store.create("persistent", "sample")
        archive = make_archive([("hello.txt", b"before\n")])
        imported = self.store.import_archive(workspace.workspace_id, archive)
        workspace_path = self.store.path(workspace.workspace_id)
        (workspace_path / "hello.txt").write_text("after\n", encoding="utf-8")

        with self.assertRaises(WorkspaceError):
            self.store.checkpoint_persistent(workspace.workspace_id, "wrong", "0" * 64)
        bundle_before = self.store.change_bundle(workspace.workspace_id)
        with tarfile.open(fileobj=io.BytesIO(bundle_before), mode="r:gz") as result:
            manifest_before = json.load(result.extractfile("manifest.json"))
        checkpoint = self.store.checkpoint_persistent(
            workspace.workspace_id,
            workspace.workspace_id,
            manifest_before["patch_sha256"],
        )
        self.assertNotEqual(imported.baseline_tree, checkpoint.baseline_tree)

        bundle = self.store.change_bundle(workspace.workspace_id)
        with tarfile.open(fileobj=io.BytesIO(bundle), mode="r:gz") as result:
            manifest = json.load(result.extractfile("manifest.json"))
        self.assertEqual([], manifest["changes"])

    def test_link_normalization_rejects_escape(self):
        self.assertIsNone(_normalize_link(Path("a"), Path("../../outside")))


if __name__ == "__main__":
    unittest.main()

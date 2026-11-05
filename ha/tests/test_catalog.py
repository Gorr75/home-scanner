import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest

_ROOT = os.path.join(os.path.dirname(__file__), "..", "custom_components", "home_scanner")
_PACKAGE = "home_scanner_catalog_test"


def _load(name, filename):
    full = f"{_PACKAGE}.{name}"
    spec = importlib.util.spec_from_file_location(full, os.path.join(_ROOT, filename))
    module = importlib.util.module_from_spec(spec)
    module.__package__ = _PACKAGE
    sys.modules[full] = module
    spec.loader.exec_module(module)
    return module


if _PACKAGE not in sys.modules:
    package = types.ModuleType(_PACKAGE)
    package.__path__ = [_ROOT]
    sys.modules[_PACKAGE] = package

_PATHS = _load("paths", "paths.py")
_CATALOG = _load("catalog", "catalog.py")


class CatalogTests(unittest.TestCase):
    def test_display_name_prefers_a_single_room(self):
        layout = {
            "format": "roomscan.home",
            "version": 1,
            "home": {
                "name": "Ground floor",
                "rooms": [{"name": "Kitchen"}],
            },
        }
        self.assertEqual(_CATALOG.display_name(layout, "slug"), "Kitchen")
        layout["home"]["rooms"].append({"name": "Hall"})
        self.assertEqual(_CATALOG.display_name(layout, "slug"), "Ground floor")
        self.assertEqual(_CATALOG.display_name("nope", "slug"), "slug")

    def test_scan_lists_layout_folders_and_writes_index(self):
        with tempfile.TemporaryDirectory() as config:
            slug = "6F0C2A10-4B1E-4E0A-9C11-000000000010"
            folder = _PATHS.destination_dir(config, slug)
            os.makedirs(folder)
            layout = {
                "format": "roomscan.home",
                "version": 1,
                "home": {"name": "Sample", "rooms": [{"name": "Kitchen"}]},
            }
            with open(os.path.join(folder, "layout.json"), "w", encoding="utf-8") as handle:
                json.dump(layout, handle)
            with open(os.path.join(folder, "model.glb"), "wb") as handle:
                handle.write(b"glb")
            index = _CATALOG.publish_index(config)
            self.assertEqual(index["format"], "home_scanner.index")
            self.assertEqual(len(index["rooms"]), 1)
            room = index["rooms"][0]
            self.assertEqual(room["slug"], slug)
            self.assertEqual(room["name"], "Kitchen")
            self.assertEqual(room["files"], ["layout.json", "model.glb"])
            self.assertTrue(room["path"].endswith(slug + "/"))
            stored = os.path.join(config, "www", "home_scanner", "index.json")
            with open(stored, encoding="utf-8") as handle:
                self.assertEqual(json.load(handle)["rooms"][0]["name"], "Kitchen")

    def test_unsafe_folder_names_are_skipped(self):
        with tempfile.TemporaryDirectory() as config:
            root = os.path.join(config, "www", "home_scanner")
            os.makedirs(os.path.join(root, "..hidden"))
            index = _CATALOG.scan_index(config)
            self.assertEqual(index["rooms"], [])


if __name__ == "__main__":
    unittest.main()

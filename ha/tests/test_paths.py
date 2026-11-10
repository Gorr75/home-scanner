import importlib.util
import os
import tempfile
import unittest

_PATHS = os.path.join(
    os.path.dirname(__file__),
    "..",
    "custom_components",
    "home_scanner",
    "paths.py",
)
_SPEC = importlib.util.spec_from_file_location("home_scanner_paths", _PATHS)
_MODULE = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_MODULE)
destination_dir = _MODULE.destination_dir
safe_slug = _MODULE.safe_slug
accepted_upload_name = _MODULE.accepted_upload_name
upload_destination = _MODULE.upload_destination


class PathTests(unittest.TestCase):
    def test_slug(self):
        self.assertEqual(
            safe_slug("6F0C2A10-4B1E-4E0A-9C11-000000000010"),
            "6F0C2A10-4B1E-4E0A-9C11-000000000010",
        )
        self.assertIsNone(safe_slug("../etc"))
        self.assertIsNone(safe_slug("rooms/kitchen"))
        self.assertIsNone(safe_slug(""))
        self.assertIsNone(safe_slug("."))

    def test_destination_stays_under_www(self):
        with tempfile.TemporaryDirectory() as config:
            dest = destination_dir(config, "Kitchen_1")
            root = os.path.realpath(os.path.join(config, "www", "home_scanner"))
            self.assertTrue(dest.startswith(root + os.sep))
            self.assertTrue(dest.endswith(os.path.join("home_scanner", "Kitchen_1")))
            with self.assertRaises(ValueError):
                destination_dir(config, "../etc")

    def test_plate_names_and_destinations(self):
        pin = "6F0C2A10-4B1E-4E0A-9C11-000000000031"
        self.assertTrue(accepted_upload_name("layout.json"))
        self.assertTrue(accepted_upload_name("model.glb"))
        self.assertTrue(accepted_upload_name("model.usdz"))
        self.assertTrue(accepted_upload_name("plates/manifest.json"))
        self.assertTrue(accepted_upload_name("plates/day/base.jpg"))
        self.assertTrue(accepted_upload_name("plates/night/base.jpg"))
        self.assertTrue(accepted_upload_name(f"plates/night/{pin}.png"))
        self.assertFalse(accepted_upload_name("plates/../layout.json"))
        self.assertFalse(accepted_upload_name("plates/day/not-a-uuid.png"))
        self.assertFalse(accepted_upload_name("plates/day/base.png"))
        self.assertFalse(accepted_upload_name("notes.txt"))
        self.assertFalse(accepted_upload_name(None))
        with tempfile.TemporaryDirectory() as folder:
            dest = upload_destination(folder, "plates/day/base.jpg")
            root = os.path.realpath(folder)
            self.assertTrue(dest.startswith(root + os.sep))
            self.assertTrue(dest.endswith(os.path.join("plates", "day", "base.jpg")))
            with self.assertRaises(ValueError):
                upload_destination(folder, "../etc/passwd")


if __name__ == "__main__":
    unittest.main()

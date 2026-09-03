import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from scripts.update_lms_plugins_repo import update


class UpdateFeedTest(unittest.TestCase):
    def test_replaces_only_ext_entries_for_all_platforms(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "repo.xml"
            path.write_text(
                "<extensions><plugins>"
                '<plugin name="Other" version="1"><target>unix</target></plugin>'
                '<plugin name="BlissMixerExt" version="0"><target>unix</target></plugin>'
                "</plugins></extensions>",
                encoding="utf-8",
            )
            packages = (
                ("unix", "https://example/linux.zip", "linux-sha"),
                ("mac", "https://example/mac.zip", "mac-sha"),
                ("windows", "https://example/windows.zip", "windows-sha"),
            )

            update(path, "0.1.0", packages)

            plugins = ET.parse(path).getroot().find("plugins")
            assert plugins is not None
            entries = plugins.findall("plugin")
            self.assertEqual(entries[0].get("name"), "Other")
            ext = [entry for entry in entries if entry.get("name") == "BlissMixerExt"]
            self.assertEqual([entry.findtext("target") for entry in ext], ["unix", "mac", "windows"])
            self.assertTrue(all(entry.get("version") == "0.1.0" for entry in ext))
            self.assertEqual([entry.findtext("url") for entry in ext], [item[1] for item in packages])
            self.assertEqual([entry.findtext("sha") for entry in ext], [item[2] for item in packages])
            self.assertTrue(
                all(entry.findtext("title") == "Bliss Mixer Extensions" for entry in ext)
            )
            self.assertTrue(
                all(
                    entry.findtext("desc")
                    == "Experimental and early-access extensions for Bliss Mixer"
                    for entry in ext
                )
            )


if __name__ == "__main__":
    unittest.main()

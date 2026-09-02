from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "BlissMixerExt"


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


manifest = ET.parse(PLUGIN / "install.xml").getroot()
if manifest.findtext("module") != "Plugins::BlissMixerExt::Plugin":
    fail("install.xml must use the BlissMixerExt module namespace")
if manifest.findtext("name") != "BLISSMIXEREXT":
    fail("install.xml must use the BlissMixerExt name token")
if manifest.findtext("id") == "6979c1ee-0644-4ed1-a440-c5ff6869eae4":
    fail("install.xml reuses the upstream BlissMixer UUID")

plugin_source = (PLUGIN / "Plugin.pm").read_text(encoding="utf-8")
survey_source = (PLUGIN / "Survey.pm").read_text(encoding="utf-8")

required = {
    "separate preference namespace": "preferences('plugin.blissmixerext')",
    "upstream preference reader": "preferences('plugin.blissmixer')",
    "separate DSTM handler": "BLISSMIXEREXT_DSTM",
    "separate mixer binary": "findbin('bliss-mixer-ext')",
    "separate learner binary": "findbin('bliss-learner-ext')",
    "loopback-only mixer": 'push @params, "127.0.0.1"',
    "port collision guard": "conflicts with upstream BlissMixer",
}
for description, needle in required.items():
    if needle not in plugin_source + survey_source:
        fail(f"missing {description}: {needle}")

for forbidden in (
    "Plugins::BlissMixerExt::Analyser",
    "Plugins::BlissMixerExt::Importer",
    "registerInfoProvider(",
    "registerHandler(\n        blissmixer =>",
):
    if forbidden in plugin_source:
        fail(f"sidecar contains conflicting registration: {forbidden}")

settings = (PLUGIN / "HTML/EN/plugins/BlissMixerExt/settings/blissmixerext.html").read_text(encoding="utf-8")
for upstream_pref in re.findall(r'name="pref_([^"]+)"', settings):
    if upstream_pref not in {"mixer_port", "learned_blend", "triplets_backup_path"}:
        fail(f"settings page duplicates upstream preference: {upstream_pref}")

print("BlissMixerExt repository validation passed")

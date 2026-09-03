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
    "automatic loopback port selection": "_availableMixerPort",
    "canonical learned matrix": "'learned_matrix.json'",
    "canonical training triplets": "'training_triplets.json'",
    "legacy data migration": "_migrateLearningFile",
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

if 'blissmixer-triplets-${ts}.zip' not in survey_source:
    fail("training-data backups must retain the established BlissMixer filename")

settings = (PLUGIN / "HTML/EN/plugins/BlissMixerExt/settings/blissmixerext.html").read_text(encoding="utf-8")
for upstream_pref in re.findall(r'name="pref_([^"]+)"', settings):
    if upstream_pref not in {"learned_blend", "triplets_backup_path"}:
        fail(f"settings page duplicates upstream preference: {upstream_pref}")
if 'name="pref_mixer_port"' in settings:
    fail("settings page must not expose the sidecar's internal mixer port")
if "sliderInput_0_100_1" not in settings:
    fail("learned matrix influence must use the LMS slider control")
if not re.search(
    r'<input type="text" class="stdedit selectFolder" '
    r'name="pref_triplets_backup_path" id="triplets_backup_path" '
    r'value="\[% prefs\.triplets_backup_path %\]" size="40">',
    settings,
):
    fail("backup folder must use the same persistent folder-picker contract as BlissMixer")
if '<input type="hidden" class="selectFile" id="restore_backup_path" value="">' not in settings:
    fail("restore must use the same icon-only file-picker contract as BlissMixer")
if 'id="restore_path"' in settings or '<button onclick="restoreBackup()"' in settings:
    fail("restore must not expose the old text field or manual restore button")
for behavior in (
    "setRestorePathFromBackupFolder",
    "watchRestorePathSelection",
    "restoreWatchInterval = setInterval(watchRestorePathSelection, 250)",
    "backupPath.addEventListener('change', updateBackupButtonState)",
):
    if behavior not in settings:
        fail(f"backup/restore picker is missing upstream behavior: {behavior}")

settings_source = (PLUGIN / "Settings.pm").read_text(encoding="utf-8")
if "protectName('BLISSMIXEREXT')" not in settings_source:
    fail("settings menu name must use the BLISSMIXEREXT localization token")
if "$paramRef->{host}" not in settings_source:
    fail("settings JSON-RPC URL must prefer the browser-facing LMS request host")

strings_path = PLUGIN / "strings.txt"
strings_source = strings_path.read_text(encoding="utf-8")
string_tokens: set[str] = set()
for line_number, line in enumerate(strings_source.splitlines(), start=1):
    if not line:
        continue
    if line[0].isspace():
        if not re.fullmatch(r"\t[A-Z]{2}\t\S.*", line):
            fail(f"strings.txt line {line_number} is not tab-delimited LMS string data")
        continue
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", line):
        fail(f"strings.txt line {line_number} is not a valid string token")
    string_tokens.add(line)

if "BLISSMIXEREXT\n\tEN\tBliss Mixer Extensions" not in strings_source:
    fail("display name must be Bliss Mixer Extensions")
if (
    "BLISSMIXEREXT_DESC\n"
    "\tEN\tExperimental and early-access extensions for Bliss Mixer"
    not in strings_source
):
    fail("plugin description must identify experimental and early-access extensions")
if "BLISSMIXEREXT_DSTM\n\tEN\tBliss (Ext)" not in strings_source:
    fail("the Bliss (Ext) DSTM provider display name must remain stable")

referenced_tokens = {
    manifest.findtext("name"),
    manifest.findtext("description"),
    *re.findall(r'"(BLISSMIXEREXT(?:_[A-Z0-9_]+)?)"\s*\|\s*string', settings),
    *re.findall(r'(?:title|desc)="(BLISSMIXEREXT(?:_[A-Z0-9_]+)?)"', settings),
}
for token in referenced_tokens:
    if token and token not in string_tokens:
        fail(f"missing localized string token: {token}")

release_workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
for requirement in (
    "chrober/bliss-mixer",
    "chrober/bliss-learner",
    "sha256sum -c *.sha256",
    "lms-blissmixer-ext-linux-",
    "lms-blissmixer-ext-mac-",
    "lms-blissmixer-ext-windows-",
    "scripts/update_lms_plugins_repo.py",
):
    if requirement not in release_workflow:
        fail(f"release workflow is missing: {requirement}")

source_manifest = (PLUGIN / "Bin/SOURCE.md").read_text(encoding="utf-8")
for label in ("Mixer release", "Mixer commit", "Learner release", "Learner commit"):
    if not re.search(rf"{label}:\s*`[^`]+`", source_manifest):
        fail(f"binary provenance is missing {label}")

print("BlissMixerExt repository validation passed")

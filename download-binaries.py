#!/usr/bin/env python3

#
# LMS-BlissMixerExt
#
# Copyright (c) 2022-2026 Craig Drummond <craig.p.drummond@gmail.com>
# MIT license.
#

import datetime, hashlib, os, requests, shutil, subprocess, sys, tempfile, time, zipfile

PLUGIN_NAME = "BlissMixerExt"
GITHUB_TOKEN_FILE = "%s/.config/github-token" % os.path.expanduser('~')
MIXER_GITHUB_REPO = "chrober/bliss-mixer"
MIXER_GITHUB_ARTIFACTS = {"bliss-mixer-linux-x86": {"bliss-mixer": "x86_64-linux/bliss-mixer-ext"},
                          "bliss-mixer-linux-arm": {"bin/bliss-mixer-armhf": "armhf-linux/bliss-mixer-ext", "bin/bliss-mixer-aarch64": "aarch64-linux/bliss-mixer-ext"},
                          "bliss-mixer-mac":       {"bliss-mixer": "mac/bliss-mixer-ext"},
                          "bliss-mixer-windows":   {"bliss-mixer.exe": "windows/bliss-mixer-ext.exe"}}
LEARNER_GITHUB_REPO = "chrober/bliss-learner"
LEARNER_GITHUB_ARTIFACTS = {"bliss-learner-linux-x86": {"bliss-learner": "x86_64-linux/bliss-learner-ext"},
                            "bliss-learner-linux-arm": {"bin/bliss-learner-armhf": "armhf-linux/bliss-learner-ext", "bin/bliss-learner-aarch64": "aarch64-linux/bliss-learner-ext"},
                            "bliss-learner-mac":       {"bliss-learner": "mac/bliss-learner-ext"},
                            "bliss-learner-windows":   {"bliss-learner.exe": "windows/bliss-learner-ext.exe"}}


def info(s):
    print("INFO: %s" %s)


def error(s):
    print("ERROR: %s" % s)
    exit(-1)


def to_time(tstr):
    return time.mktime(datetime.datetime.strptime(tstr, "%Y-%m-%dT%H:%M:%SZ").timetuple())


def get_items(repo, artifacts):
    info("Getting artifact list for %s" % repo)
    js = requests.get("https://api.github.com/repos/%s/actions/artifacts" % repo).json()
    if js is None or not "artifacts" in js:
        error("Failed to list artifacts")

    items={}
    for a in js["artifacts"]:
        if a["name"] in artifacts and (not a["name"] in items or to_time(a["created_at"])>items[a["name"]]["date"]):
            items[a["name"]]={"date":to_time(a["created_at"]), "url":a["archive_download_url"]}

    return items


def getMd5sum(path):
    if not os.path.exists(path):
        return '000'
    md5 = hashlib.md5()
    with open(path, 'rb') as f:
        while True:
            data = f.read(65535)
            if not data:
                break
            md5.update(data)
    return md5.hexdigest()


def download_artifacts(repo, artifacts):
    items = get_items(repo, artifacts)
    if len(items)!=len(artifacts):
        error("Failed to determine all artifacts (%d != %d)" % (len(items), len(artifacts)))
    token = os.environ.get("GITHUB_TOKEN")
    if not token and os.path.exists(GITHUB_TOKEN_FILE):
        with open(GITHUB_TOKEN_FILE, "r") as f:
            token = f.readlines()[0].strip()
    if not token:
        try:
            token = subprocess.check_output(
                ["gh", "auth", "token"], text=True
            ).strip()
        except (OSError, subprocess.CalledProcessError):
            error("GitHub token not found; set GITHUB_TOKEN or authenticate with gh")
    headers = {"Authorization": "token %s" % token}
    ok = True
    updated = False

    for name in items:
        with tempfile.TemporaryDirectory() as td:
            artifact = artifacts[name]
            url = items[name]["url"]
            info("Downloading %s" % url)
            r = requests.get(url, headers=headers, stream=True)
            dest = os.path.join(td, name+".zip")
            with open(dest, 'wb') as f:
                for chunk in r.iter_content(chunk_size=1024*1024):
                    if chunk:
                        f.write(chunk)
            if not os.path.exists(dest):
                info("Failed to download %s" % url)
                ok = False
                break

            with zipfile.ZipFile(dest, 'r') as zf:
                zf.extractall(td)

            for a in artifact:
                asrc = "%s/%s" % (td, a)
                adest = "%s/%s/Bin/%s" % (os.path.dirname(os.path.abspath(__file__)), PLUGIN_NAME, artifact[a])
                srcMd5 = getMd5sum(asrc)
                destMd5 = getMd5sum(adest)
                if srcMd5!=destMd5:
                    os.makedirs(os.path.dirname(adest), exist_ok=True)
                    info("Moving %s to %s" % (a, adest))
                    shutil.move("%s/%s" % (td, a), adest)
                    if sys.platform != 'win32':
                        subprocess.call(["chmod", "a+x", adest], shell=False)
                    updated = True

    if not ok:
        error("Failed to download artifacts")
    elif not updated:
        info("No changes")


if len(sys.argv)<2 or sys.argv[1]=='mixer':
    download_artifacts(MIXER_GITHUB_REPO, MIXER_GITHUB_ARTIFACTS)
if len(sys.argv)<2 or sys.argv[1]=='learner':
    download_artifacts(LEARNER_GITHUB_REPO, LEARNER_GITHUB_ARTIFACTS)

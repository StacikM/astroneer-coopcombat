"""Builds the friend package: dist/CoopCombat-update.zip + dist/version.txt

Usage: python build_package.py
- UE4SS files come from your game folder (so the zip matches what you test with)
- the mod comes from ../mods/CoopCombat
- set the update link in update_url.txt (one line, folder URL that holds version.txt and CoopCombat-update.zip)
"""
import json
import os
import re
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
WIN64 = r"C:\Program Files (x86)\Steam\steamapps\common\ASTRONEER\Astro\Binaries\Win64"
SRC = os.path.join(HERE, "src")
DIST = os.path.join(HERE, "dist")
MOD = os.path.join(PROJECT, "mods", "CoopCombat")
os.makedirs(DIST, exist_ok=True)

version = time.strftime("%Y.%m.%d-%H%M%S")
SKIP_DIRS = {"CXXHeaderDump", "panel", "updater", "CoopCombat.backup"}
SKIP_FILES = {"UE4SS.log", "imgui.ini", "UE4SS_ObjectDump.txt"}


def add(z, full, arc):
    z.write(full, arc.replace(os.sep, "/"))


url_file = os.path.join(HERE, "update_url.txt")
update_url = open(url_file, encoding="utf-8").read() if os.path.exists(url_file) else "# paste the update link here\n"

out = os.path.join(DIST, "CoopCombat-update.zip")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.write(os.path.join(WIN64, "dwmapi.dll"), "payload/dwmapi.dll")
    ue = os.path.join(WIN64, "ue4ss")
    for root, dirs, files in os.walk(ue):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if f in SKIP_FILES or f.lower().endswith(".dmp"):
                continue
            full = os.path.join(root, f)
            rel = os.path.join("ue4ss", os.path.relpath(full, ue))
            arc = "payload/" + rel.replace(os.sep, "/")
            norm = rel.replace(os.sep, "/")
            if norm.startswith("ue4ss/Mods/CoopCombat/"):
                continue  # the mod itself is taken from the project below
            if f == "UE4SS-settings.ini":
                txt = re.sub(r"(?m)^GuiConsoleVisible = 1", "GuiConsoleVisible = 0", open(full, encoding="utf-8").read())
                z.writestr(arc, txt)
            elif f == "mods.txt":
                txt = open(full, encoding="utf-8-sig").read().replace("CoopCombat : 0", "CoopCombat : 1")
                z.writestr(arc, txt)
            elif f == "mods.json":
                d = json.load(open(full, encoding="utf-8-sig"))
                for m in d:
                    if m["mod_name"] == "CoopCombat":
                        m["mod_enabled"] = True
                z.writestr(arc, json.dumps(d, indent=4))
            else:
                z.write(full, arc)
    # the mod: only the scripts
    for root, _, files in os.walk(os.path.join(MOD, "Scripts")):
        for f in files:
            full = os.path.join(root, f)
            rel = os.path.relpath(full, MOD)
            z.write(full, "payload/ue4ss/Mods/CoopCombat/" + rel.replace(os.sep, "/"))
    z.writestr("payload/ue4ss/Mods/CoopCombat/version.txt", version + "\n")
    # installer files
    z.write(os.path.join(SRC, "install.ps1"), "install.ps1")
    z.write(os.path.join(SRC, "Install-or-Update.bat"), "Install-or-Update.bat")
    z.writestr("update_url.txt", update_url)
    z.writestr("README.txt",
               "1. Extract this zip anywhere (e.g. your Desktop).\n"
               "2. Double-click Install-or-Update.bat.\n"
               "That's it. To update later, double-click 'Update CoopCombat' on your Desktop.\n"
               "Needs Astroneer (Steam) closed while installing.\n"
               "Experimental mod: it can crash the game. Only use it with friends.\n")

with open(os.path.join(DIST, "version.txt"), "w", encoding="utf-8") as f:
    f.write(version + "\n")
print("built", out, round(os.path.getsize(out) / 1e6, 2), "MB, version", version)

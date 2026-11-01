"""The Roblox adapter (autopilot/engines/roblox.py) and plugin (plugin/roblox) without Studio: projects on disk (a Rojo
project, a place file), the codex's files and index, the kit frame, the game backend's things, the teleport, the
Roblox section of the implementer's prompt, the plugin's build (one .rbxmx with every module) and its sources (each
module it requires is there, every op the brain needs is answered somewhere)."""

import json
import os
import re
import shutil
import subprocess
import sys

import pytest

from autopilot import bridge, engines, research
from autopilot.kit.game import Game
from autopilot.kit.geom import Vec

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "plugin", "roblox", "src")
sys.path.insert(0, os.path.join(ROOT, "tools"))


def _rojo(tmp_path):
    d = tmp_path / "skyfarm"
    (d / "src" / "server").mkdir(parents=True)
    (d / "src" / "client").mkdir(parents=True)
    (d / "Packages" / "Lib").mkdir(parents=True)
    (d / "default.project.json").write_text(json.dumps({"name": "Sky Farm", "tree": {"$className": "DataModel"}}))
    (d / "src" / "server" / "Farm.server.luau").write_text("print('farm')")
    (d / "src" / "client" / "Hud.client.lua").write_text("print('hud')")
    (d / "Packages" / "Lib" / "init.lua").write_text("return {}")
    (d / "notes.png").write_bytes(b"\x89PNG")
    return d


def test_projects_on_disk(tmp_path):
    rb = engines.get("roblox")
    d = _rojo(tmp_path)
    assert rb.project_at(str(d)) == str(d)
    assert rb.project_at(str(d / "default.project.json")) == str(d)
    assert rb.project_name(str(d)) == "Sky Farm"  # (the Rojo project's own name)
    place = tmp_path / "places" / "Obby World.rbxl"
    place.parent.mkdir()
    place.write_bytes(b"<roblox!")
    assert rb.project_at(str(place)) == str(place)
    assert rb.project_at(str(place.parent)) == str(place)  # (a folder of one place file)
    assert rb.project_name(str(place)) == "Obby World"  # (as Studio names the place: its file)
    assert rb.project_at(str(tmp_path / "nothing")) is None
    eng, found = engines.find_project(str(d))
    assert eng.name == "roblox" and found == str(d)


def test_codex_paths():
    rb = engines.get("roblox")
    for ok in ("src/ServerScriptService/GameManager.server.luau", "src/StarterGui/HUD/Hud.client.luau",
               "src/ReplicatedStorage/Modules/Config.luau", "src/Workspace/Door/DoorScript.server.luau"):
        assert rb.codex_path(ok) == ok, ok
    assert rb.codex_path(".autopilot/summary.txt") == "summary.txt"
    assert rb.codex_path(".autopilot/tree/Workspace.txt") == "tree/Workspace.txt"
    for bad in ("src/../x.luau", "/src/x.luau", "src\\x.luau", "C:/x.luau", "src/x.txt", "other/x.luau",
                ".autopilot/README.md", ".autopilot/level.txt", "local/x.luau", "x.luau", ".autopilot/x.json"):
        assert rb.codex_path(bad) is None, bad


def test_local_codex_of_a_rojo_project(tmp_path):
    rb = engines.get("roblox")
    d = _rojo(tmp_path)
    root = tmp_path / "codex"
    root.mkdir()
    assert rb.copy_source(str(d), str(root)) == 3
    have = sorted(str(p.relative_to(root)).replace(os.sep, "/") for p in root.rglob("*") if p.is_file())
    assert have == ["local/default.project.json", "local/src/client/Hud.client.lua",
                    "local/src/server/Farm.server.luau"]
    # (a place file holds its scripts inside: only the plugin reads those)
    place = tmp_path / "One.rbxl"
    place.write_bytes(b"<roblox!")
    assert rb.copy_source(str(place), str(tmp_path / "codex2")) == 0


def test_codex_index_says_where_to_start(tmp_path):
    rb = engines.get("roblox")
    root = tmp_path / "codex"
    (root / "src" / "ServerScriptService").mkdir(parents=True)
    (root / "tree").mkdir()
    (root / "src" / "ServerScriptService" / "Main.server.luau").write_text("print(1)")
    (root / "tree" / "Workspace.txt").write_text("# Workspace")
    (root / "summary.txt").write_text("Roblox place: Sky Farm")
    assert rb.has_export(str(root))
    rb.write_index(str(root), "Sky Farm")
    text = (root / "README.md").read_text(encoding="utf-8")
    assert "Roblox project" in text and ".server.luau" in text and "tree/<Service>.txt" in text
    assert "summary.txt" in text and ".autopilot/" in text


class ThingsLink:
    def __init__(self):
        self.hello = {"project": "Sky Farm", "engine": "roblox"}
        self.asked = []
        self.written = []
        self.game_time = 3.0

    def request(self, op, args=None, timeout=None):
        self.asked.append((op, args))
        if op == "find":
            if args.get("things"):
                return {"objects": ["/Workspace/Barn", "/Workspace/Crops/Carrot@41", "/Workspace/Crops/Carrot@42"]}
            return {"objects": ["/Workspace", "/Workspace/Barn", "/Workspace/Barn/Door", "/Workspace/Crops/Carrot@41"]}
        if op == "transforms":
            return {"objects": {o: {"location": {"X": 28, "Y": 0, "Z": 56}} for o in args["objects"]}}
        if op == "rc":
            self.written.append(args["body"])
            return {}
        if op == "context":
            return {"character": "/Workspace/Farmer", "controller": "/Players/Farmer"}
        raise AssertionError(op)


def test_all_actors_are_the_workspaces_things():
    link = ThingsLink()
    game = Game(link)
    assert game.engine.name == "roblox"
    assert game.all_actors() == ["/Workspace/Barn", "/Workspace/Crops/Carrot@41", "/Workspace/Crops/Carrot@42"]
    assert link.asked[-1] == ("find", {"things": True})
    assert game.named("carrot") == ["/Workspace/Crops/Carrot@41", "/Workspace/Crops/Carrot@42"]
    assert game.name_of("/Workspace/Crops/Carrot@41") == "Carrot@41"
    assert game.locs(["/Workspace/Barn"]) == {"/Workspace/Barn": Vec(28, 0, 56)}


def test_teleport_moves_the_pivot(monkeypatch):
    link = ThingsLink()
    game = Game(link)
    monkeypatch.setattr(research.time, "sleep", lambda s: None)
    out = research.teleport(game, Vec(280, 56, 28), why="measure the jump")
    body = link.written[-1]
    assert body["objectPath"] == "/Workspace/Farmer" and body["propertyName"] == "position"
    assert body["propertyValue"] == {"position": {"x": 2.0, "y": 1.0, "z": -10.0}}
    assert game.writes[-1]["why"] == "measure the jump" and "landed" in out


def test_no_headless_launch():
    with pytest.raises(NotImplementedError, match="Studio"):
        engines.get("roblox").launch_command("p", "ws://x", "log")


def test_prompt_roblox_section_is_general():
    from autopilot.agents import session

    text = session.system_prompt(engines.get("roblox"), "runs/r")
    section = text[text.index("## The engine: Roblox"):]
    for needle in ("server", "client", "client:", "server:", "@", "tag:", "leaderstats", "ModuleScript", "to_kit",
                   "28", "ProximityPrompt", "ClickDetector", "right mouse button", "game.restart()", "omitted",
                   "no picture"):
        assert needle in section, needle
    # nothing of a particular game (the test game's names stay out of the brain)
    for word in ("Lantern", "Grove", "Mailbox", "Crate", "Lever", "Gate", "Pond", "GameState", "Ring", "Wave"):
        assert not re.search(rf"\b{word}\b", section), word


# -- the plugin ---------------------------------------------------------------------------------------------

def _sources():
    return {f[:-5]: open(os.path.join(SRC, f), encoding="utf-8").read() for f in os.listdir(SRC) if f.endswith(".luau")}


def test_the_plugin_builds_as_one_model_with_every_module(tmp_path):
    import build_roblox

    out = build_roblox.build(str(tmp_path / "Autopilot.rbxmx"))
    text = open(out, encoding="utf-8").read()
    names = re.findall(r'<Item class="ModuleScript" referent="RBX\d+"><Properties><string name="Name">(\w+)</string>',
                       text)
    assert sorted(names) == sorted(_sources()) and "Main" in names
    assert text.count('<Item class="Script"') == 1 and "require(script.Main).start(plugin, {})" in text
    assert "DevRelay" not in names  # (the dev loader's, never the built plugin's)
    # A source with "]]>" in it survives the CDATA
    xml = build_roblox.model_xml({"Main": "local s = [[a]]>b]]\nreturn {}"})
    import xml.etree.ElementTree as ET

    item = ET.fromstring(xml).find(".//Item[@class='ModuleScript']")
    assert item.find("Properties/ProtectedString").text == "local s = [[a]]>b]]\nreturn {}"


def test_every_module_the_plugin_requires_is_there():
    sources = _sources()
    for name, src in sources.items():
        for needed in re.findall(r"require\(script\.Parent\.(\w+)\)", src):
            assert needed in sources, f"{name} requires {needed}"


def test_the_plugin_answers_every_op_the_brain_needs():
    """Each op of bridge.required_ops for a Roblox hello is answered: by the play session's client (Client.luau's ops)
    or by the editor itself (Editor.luau)."""
    sources = _sources()
    client = sources["Client"]
    ops_table = client[client.index("local ops: { [string]: any } = {"):]
    answered = set(re.findall(r"^\t\t(\w+) = ", ops_table, re.M))
    editor = sources["Editor"]
    answered |= set(re.findall(r'op == "(\w+)"', editor))
    needed = set(bridge.required_ops({"engine": "roblox"}))
    assert needed <= answered, needed - answered
    assert {"levels", "codex_manifest", "codex_read", "pointer", "move", "pause"} <= answered


def test_the_plugins_hello_is_what_the_brain_reads():
    editor = _sources()["Editor"]
    hello = editor[editor.index('local h: any = { type = "hello"'):]
    hello = hello[:hello.index("}\n")]
    for field in ('engine = "roblox"', 'host = "editor"', "protocol = Link.PROTOCOL", '"levels"', '"timed_hold"',
                  "share ="):
        assert field in hello, field
    assert '"media"' not in hello  # (Studio gives a plugin no picture of the game)


def test_the_plugin_compiles():
    """Every module is valid Luau (when a Luau compiler is on PATH: luau-compile, from github.com/luau-lang/luau)."""
    exe = shutil.which("luau-compile")
    if not exe:
        pytest.skip("no luau-compile on PATH")
    paths = [os.path.join(SRC, name + ".luau") for name in sorted(_sources())]
    cases = os.path.join(ROOT, "plugin", "roblox", "tests")
    paths += [os.path.join(cases, name) for name in sorted(os.listdir(cases)) if name.endswith(".luau")]
    for path in paths:
        r = subprocess.run([exe, "--text", path], capture_output=True, text=True)
        assert r.returncode == 0, f"{path}: {r.stdout[-500:]}{r.stderr[-500:]}"

"""Harnesses for tests/robloxsim.py's place, and a suite runner on it, for test_regress.py and test_evolve.py: no
Studio, no language model, no Jev (FakeJev picks).

The harnesses import the project's `lib` (lib.arrived(distance_cm)) and `tuning` (tuning.SETTLE_TICKS) from a memory
folder the test writes, so a change to either changes how the suite goes: what autopilot evolve's lib: and const:
targets need.
"""

import concurrent.futures as futures
import os
import shutil
import sys
import threading
import time
import types

import robloxsim

from autopilot import runtime
from autopilot.engines import roblox
from autopilot.engines import roblox_mcp as mcp
from autopilot.kit.game import Game

LIB = '''def arrived(distance):
    """Whether the player stands at a target distance_cm away."""
    return distance < 10
'''
TUNING = "SETTLE_TICKS = 10  # ticks an option waits before it moves\n"

GO = '''from autopilot.kit import Harness, Option, Status
import lib
import tuning


def go(target):
    def run(game, obs):
        for _ in range(tuning.SETTLE_TICKS):
            yield
        game.request("move", {"to": target.ue()})
        yield
    return run


def idle(game, obs):
    for _ in range(3):
        yield


class Go(Harness):
    goal = "walk to the __thing__"
    tempo = 10.0
    tick_hz = 20.0
    stall_seconds = 0

    def setup(self, game):
        self.target = game.loc("Workspace/__Thing__")

    def observe(self, game):
        return {"distance": round(game.pose()["at"].dist(self.target))}

    def options(self, obs):
        return [Option("go_to___thing__", "walk to the __thing__", go(self.target)),
                Option("look_around", "look around", idle)]

    def status(self, obs):
        if lib.arrived(obs["distance"]):
            return Status("done", "next to the __thing__", {"near___thing__": True, "distance": obs["distance"]})
        return Status()
'''

COUNT = '''from autopilot.kit import Harness, Option, Status


def idle(game, obs):
    for _ in range(2):
        yield


class Count(Harness):
    goal = "read the coin count"
    tempo = 10.0
    tick_hz = 20.0
    stall_seconds = 0

    def observe(self, game):
        return {"coins": game.get("Players/Hero/leaderstats", "Coins")}

    def options(self, obs):
        return [Option("check_coins", "read the count", idle), Option("wait", "wait", idle)]

    def status(self, obs):
        if game_time_ok(obs):
            return Status("done", "the count read", {"coins": obs["coins"]})
        return Status()


def game_time_ok(obs):
    return obs.get("coins") is not None
'''

HARNESSES = {"coin": GO.replace("__thing__", "coin").replace("__Thing__", "Coin"),
             "door": GO.replace("__thing__", "door").replace("__Thing__", "Door"),
             "count": COUNT}
LIKES = {"coin": "go_to_coin", "door": "go_to_door", "count": "check_coins"}

SUITE = {"prompts": [
    {"id": "A", "prompt": "Verify that walking to the coin brings the player next to it", "expected": "CONFIRMED",
     "harness": "coin"},
    {"id": "B", "prompt": "Reach the door", "expected": "achieved", "harness": "door"},
    {"id": "C", "prompt": "Verify that the player starts with 0 coins", "expected": "CONFIRMED", "harness": "count"},
]}


class FakeJev:
    """Prefers the option named `likes` when offered, else the first."""

    def __init__(self, likes):
        self.likes = likes

    def system_one(self, state, questions):
        names = list(questions["pick"].criteria)
        best = self.likes if self.likes in names else names[0]
        probs = {n: (0.8 if n == best else 0.2 / max(1, len(names) - 1)) for n in names}
        ns = types.SimpleNamespace
        return ns(choices={"pick": ns(choice=best, probabilities=probs, confidence=0.8)}, nouls={}, scores={})


def connect(place=None):
    place = place or robloxsim.Place()
    studio = mcp.Studio.connect(mcp.LocalTransport(place.server()))
    backend = roblox.StudioBackend(studio)
    return Game(roblox.LocalLink(backend)), backend, place


def fresh_imports(memory):
    """lib and tuning from memory, as the files are now (no stale module or bytecode)."""
    for name in ("lib", "tuning"):
        sys.modules.pop(name, None)
    shutil.rmtree(os.path.join(memory, "__pycache__"), ignore_errors=True)
    if memory not in sys.path:
        sys.path.insert(0, memory)


def write_memory(memory, lib=LIB, tuning=TUNING):
    os.makedirs(memory, exist_ok=True)
    with open(os.path.join(memory, "lib.py"), "w", encoding="utf-8") as f:
        f.write(lib)
    with open(os.path.join(memory, "tuning.py"), "w", encoding="utf-8") as f:
        f.write(tuning)


def play(run_dir, which, n=1, max_seconds=3.0, memory=None):
    """One episode of harness `which` on a fresh simulated place, as a session plays one: run_dir/harness<n>.py and
    trace<n>.jsonl. The runtime's result."""
    os.makedirs(run_dir, exist_ok=True)
    path = os.path.join(run_dir, "harness.py")
    with open(path, "w", encoding="utf-8") as f:
        f.write(HARNESSES[which])
    if memory:
        fresh_imports(memory)
    harness = runtime.load_harness(path)
    game, backend, _ = connect()
    try:
        game.restart()
        game.pause(False)
        rt = runtime.Runtime(game, harness, os.path.join(run_dir, f"trace{n}.jsonl"), client=FakeJev(LIKES[which]),
                             max_seconds=max_seconds)
        result = rt.run()
    finally:
        backend.close()
    shutil.copyfile(path, os.path.join(run_dir, f"harness{n}.py"))
    return result


def outcome(item, result):
    done = (result.get("status") or {}).get("state") == "done"
    if item["prompt"].lower().startswith("verify"):
        return "CONFIRMED" if done else "INCONCLUSIVE"
    return "achieved" if done else "not_achieved"


class SimSuite:
    """evolve's run_suite on the simulated place: every prompt at once (threads), each on a place of its own; tokens
    a fixed 1000 a prompt. spans: (start, end) of each prompt, by run."""

    def __init__(self, memory, suite=SUITE, max_seconds=3.0):
        self.memory, self.suite, self.max_seconds = memory, suite, max_seconds
        self.spans = []
        self.lock = threading.Lock()

    def __call__(self, out):
        fresh_imports(self.memory)
        harnesses = {}
        for item in self.suite["prompts"]:  # (loaded one by one: `import lib` once per suite run)
            folder = os.path.join(out, item["id"])
            os.makedirs(folder, exist_ok=True)
            path = os.path.join(folder, "harness.py")
            with open(path, "w", encoding="utf-8") as f:
                f.write(HARNESSES[item["harness"]])
            harnesses[item["id"]] = runtime.load_harness(path)
        spans = []

        def one(item):
            t0 = time.monotonic()
            game, backend, _ = connect()
            try:
                game.restart()
                game.pause(False)
                rt = runtime.Runtime(game, harnesses[item["id"]], os.path.join(out, item["id"], "trace1.jsonl"),
                                     client=FakeJev(LIKES[item["harness"]]), max_seconds=self.max_seconds)
                result = rt.run()
            finally:
                backend.close()
            t1 = time.monotonic()
            with self.lock:
                spans.append((t0, t1))
            got = outcome(item, result)
            return {"id": item["id"], "prompt": item["prompt"], "expected": item["expected"], "got": got,
                    "correct": got == item["expected"], "seconds": round(t1 - t0, 3), "tokens": 1000,
                    "summary": (result.get("status") or {}).get("note") or result.get("reason")}

        with futures.ThreadPoolExecutor(len(self.suite["prompts"])) as pool:
            results = list(pool.map(one, self.suite["prompts"]))
        self.spans.append(spans)
        return results

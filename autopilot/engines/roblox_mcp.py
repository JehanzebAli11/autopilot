"""Roblox Studio's built-in MCP server ("StudioMCP"), as the Roblox engine reaches it: a minimal MCP client over stdio
(JSON-RPC 2.0, one JSON message a line: initialize, tools/list, tools/call, with timeouts), the Studio tools it uses,
and FakeStudio, a stand-in server for the tests (no Studio needed).

Every tool name and argument shape the engine depends on is in this module and nowhere else. Roblox documents the
tools' names and what they take (create.roblox.com/docs/studio/mcp) but not their exact JSON schemas, so the argument
names are picked from the schema each tool advertises in tools/list when it advertises one, and fall back to the
guesses marked TODO(verify) below. Everything here is checked against FakeStudio only: verify the TODOs against a live
server's tools/list (`python tools/roblox_latency.py --tools` prints it) before relying on them.

The server's command: AUTOPILOT_ROBLOX_MCP_CMD (a command line), else the one Roblox documents for the platform
(Windows: `cmd.exe /c %LOCALAPPDATA%\\Roblox\\mcp.bat`; macOS: /Applications/RobloxStudio.app/Contents/MacOS/StudioMCP).
"""

import base64
import collections
import itertools
import json
import os
import shlex
import subprocess
import sys
import threading
import time

import autopilot

PROTOCOL_VERSION = "2025-06-18"  # (the MCP revision asked for; the server answers with the one it speaks)
ENV_CMD = "AUTOPILOT_ROBLOX_MCP_CMD"
ENV_STUDIO_ID = "AUTOPILOT_ROBLOX_STUDIO_ID"  # which Studio, when the server is connected to more than one
# The bench gives each brain a settings folder of its own by moving LOCALAPPDATA (bench/run_autopilot.py); Studio's
# mcp.bat lives in the real one, which the bench passes on here for the server's process
ENV_LOCALAPPDATA = "AUTOPILOT_ROBLOX_LOCALAPPDATA"
# How execute_luau gives back what a chunk worked out: "return" (the chunk's return value comes back in the tool's
# result) or "print" (only printed output does: the chunk prints its JSON between markers). TODO(verify): which one
# the live server does; the parser reads either way, this only decides whether the chunk also prints (which puts every
# read into Studio's Output window)
ENV_RESULT = "AUTOPILOT_ROBLOX_RESULT"
TIMEOUT = 30.0  # seconds to wait for an answer to a request
START_TIMEOUT = 60.0  # ... for initialize (Studio may still be starting)

# -- the tools ---------------------------------------------------------------------------------------------------
# (names from Roblox's docs, create.roblox.com/docs/studio/mcp, 2026-11)
EXECUTE_LUAU = "execute_luau"
START_STOP_PLAY = "start_stop_play"
GET_CONSOLE_OUTPUT = "get_console_output"
GET_STUDIO_STATE = "get_studio_state"
SCREEN_CAPTURE = "screen_capture"
SEARCH_GAME_TREE = "search_game_tree"
INSPECT_INSTANCE = "inspect_instance"
SCRIPT_READ = "script_read"
SCRIPT_GREP = "script_grep"
USER_KEYBOARD_INPUT = "user_keyboard_input"
USER_MOUSE_INPUT = "user_mouse_input"
CHARACTER_NAVIGATION = "character_navigation"
LIST_ROBLOX_STUDIOS = "list_roblox_studios"

# The engine can't play without these; the rest it does without (what each lack costs: OPTIONAL)
REQUIRED = (EXECUTE_LUAU, START_STOP_PLAY, GET_CONSOLE_OUTPUT)
OPTIONAL = {
    GET_STUDIO_STATE: "whether a play session runs is tracked by the engine itself",
    SCREEN_CAPTURE: "no pictures of the game (no stills, no describe_frames)",
    SEARCH_GAME_TREE: "the codex has no dump of the place's instance tree",
    INSPECT_INSTANCE: "game.request('inspect', ...) is unavailable",
    SCRIPT_READ: "the codex can't read the place's scripts (a Rojo project's files are read from disk)",
    SCRIPT_GREP: "game.request('grep', ...) is unavailable",
    USER_KEYBOARD_INPUT: "no keyboard input: keys can't be pressed",
    USER_MOUSE_INPUT: "no mouse input: no clicks, no camera turning",
    CHARACTER_NAVIGATION: "game.request('move', {'to': ...}) is unavailable",
    LIST_ROBLOX_STUDIOS: "a server connected to several Studios needs AUTOPILOT_ROBLOX_STUDIO_ID",
}

# Argument names per tool: for each argument the engine means, the names a server may call it, the likeliest first.
# The first one the tool's advertised inputSchema has is used; with no schema, the first. TODO(verify) all of these
# against the live server's tools/list.
ARGS = {
    EXECUTE_LUAU: {"code": ("code", "source", "luau", "command", "script"),
                   "datamodel": ("datamodel_type", "data_model", "datamodel", "context")},
    START_STOP_PLAY: {"start": ("is_start", "mode", "action", "start")},
    SCREEN_CAPTURE: {"camera": ("camera_position", "position"), "look_at": ("look_at", "target")},
    SEARCH_GAME_TREE: {"path": ("path", "root", "instance_path"), "type": ("instance_type", "class_name", "type"),
                       "keywords": ("keywords", "query", "keyword"), "depth": ("max_depth", "depth", "depth_limit")},
    INSPECT_INSTANCE: {"path": ("path", "instance_path")},
    SCRIPT_READ: {"path": ("path", "script_path", "target_file"), "start": ("start_line", "from_line"),
                  "end": ("end_line", "to_line")},
    SCRIPT_GREP: {"pattern": ("pattern", "query", "search")},
    USER_KEYBOARD_INPUT: {"actions": ("actions", "inputs", "events"),
                          "datamodel": ("datamodel_type", "data_model", "datamodel")},
    USER_MOUSE_INPUT: {"actions": ("actions", "inputs", "events"),
                       "datamodel": ("datamodel_type", "data_model", "datamodel")},
    CHARACTER_NAVIGATION: {"position": ("target_position", "position", "target"),
                           "instance": ("instance_path", "target_instance", "path"),
                           "speed": ("speed_multiplier", "speed")},
}
# Data model names as execute_luau and the input tools take them (Roblox's docs: Edit, Client, Server)
DATAMODELS = ("Edit", "Client", "Server")


# The input tools' actions. Roblox's docs list what they do (keyboard: key down, key up, key press, text input, wait,
# an optional UI instance target; mouse: move, click, button down/up, scroll, wait, a target instance or screen
# coordinates) but not the JSON of an action: these builders are the one place that shape is written.
# TODO(verify) every key below against the live server's inputSchema for user_keyboard_input / user_mouse_input.

def key_action(kind, key):
    """kind: "down", "up" or "press"; key: a Roblox KeyCode name (W, Space, LeftShift, One...)."""
    return {"type": {"down": "key_down", "up": "key_up", "press": "key_press"}[kind], "key": key}


def text_action(text, target=None):
    """Type text, into a TextBox (`target`: its dot path) when given."""
    out = {"type": "text_input", "text": text}
    if target:
        out["instance_path"] = target
    return out


def wait_action(seconds):
    return {"type": "wait", "seconds": round(float(seconds), 3)}


def mouse_move(x, y):
    """Move the mouse to viewport pixels (from the top left)."""
    return {"type": "move", "x": round(x), "y": round(y)}


def mouse_click(button="left", x=None, y=None, target=None):
    """A click with a button ("left", "right", "middle") at viewport pixels, or on a GUI instance (`target`: its dot
    path)."""
    out = {"type": "click", "button": button}
    if target:
        out["instance_path"] = target
    else:
        out.update({"x": round(x or 0), "y": round(y or 0)})
    return out


def mouse_button(kind, button="left"):
    """kind: "down" or "up"."""
    return {"type": f"button_{kind}", "button": button}


def mouse_scroll(delta):
    return {"type": "scroll", "delta": delta}


class McpError(RuntimeError):
    """The server answered a request with an error, or never answered it."""

    def __init__(self, message, code=None):
        super().__init__(message)
        self.code = code


class McpTimeout(McpError):
    pass


class ToolError(McpError):
    """A tool ran and said it failed (the result's isError)."""


class ToolMissing(McpError):
    """The server doesn't offer a tool the engine needs."""


# -- the server's command --------------------------------------------------------------------------------------

def default_command(platform=None, env=None):
    """The command Roblox documents for its MCP server on this platform, as a list; None where Studio doesn't run."""
    platform = platform or sys.platform
    env = os.environ if env is None else env
    if platform == "win32":
        local = env.get(ENV_LOCALAPPDATA) or env.get("LOCALAPPDATA") or os.path.join(
            os.path.expanduser("~"), "AppData", "Local")
        return ["cmd.exe", "/c", os.path.join(local, "Roblox", "mcp.bat")]
    if platform == "darwin":
        return ["/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP"]
    return None


def command(env=None):
    """The server's command line as a list: AUTOPILOT_ROBLOX_MCP_CMD, else default_command(). Raises McpError when
    there is none (Linux has no Roblox Studio)."""
    env = os.environ if env is None else env
    given = (env.get(ENV_CMD) or "").strip()
    if given:
        return shlex.split(given, posix=os.name != "nt")
    cmd = default_command(env=env)
    if not cmd:
        raise McpError(f"no Roblox Studio MCP server on {sys.platform}: set {ENV_CMD} to the command that starts it")
    return cmd


def spawn_env(env=None):
    """The server process's environment: this one, with the user's own LOCALAPPDATA put back when the bench moved it
    (mcp.bat may read it)."""
    env = dict(os.environ if env is None else env)
    if env.get(ENV_LOCALAPPDATA):
        env["LOCALAPPDATA"] = env[ENV_LOCALAPPDATA]
    return env


# -- transports ----------------------------------------------------------------------------------------------------

class StdioTransport:
    """An MCP server run as a child process, spoken to over its stdin and stdout: one JSON message a line (MCP's stdio
    transport). Its stderr is kept (the last lines) for error messages."""

    def __init__(self, cmd, env=None, cwd=None):
        self.cmd = list(cmd)
        self.on_message = lambda msg: None
        self.on_close = lambda why: None
        self.stderr_tail = collections.deque(maxlen=40)
        self._write_lock = threading.Lock()
        try:
            self.proc = subprocess.Popen(self.cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, env=env if env is not None else spawn_env(),
                                         cwd=cwd, bufsize=0)
        except OSError as e:
            raise McpError(f"couldn't start the Roblox Studio MCP server ({' '.join(self.cmd)}): {e}") from None

    def start(self):
        threading.Thread(target=self._read, name="studio-mcp-read", daemon=True).start()
        threading.Thread(target=self._read_stderr, name="studio-mcp-stderr", daemon=True).start()

    def send(self, msg):
        data = (json.dumps(msg, separators=(",", ":")) + "\n").encode("utf-8")
        with self._write_lock:
            try:
                self.proc.stdin.write(data)
                self.proc.stdin.flush()
            except (OSError, ValueError) as e:
                raise McpError(f"the Roblox Studio MCP server is gone: {e}{self.tail()}") from None

    def _read(self):
        why = "the server's output ended"
        try:
            for raw in self.proc.stdout:
                line = raw.decode("utf-8", "replace").strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    self.stderr_tail.append(f"(not JSON on stdout) {line[:200]}")
                    continue  # (a server that logs to stdout: not a message)
                if isinstance(msg, list):  # (a JSON-RPC batch)
                    for m in msg:
                        self.on_message(m)
                elif isinstance(msg, dict):
                    self.on_message(msg)
        except (OSError, ValueError) as e:
            why = str(e)
        code = self.proc.poll()
        self.on_close(why + (f" (exit code {code})" if code is not None else "") + self.tail())

    def _read_stderr(self):
        try:
            for raw in self.proc.stderr:
                self.stderr_tail.append(raw.decode("utf-8", "replace").rstrip())
        except (OSError, ValueError):
            pass

    def tail(self):
        lines = [x for x in self.stderr_tail if x]
        return ("; its last output: " + " | ".join(lines[-5:])) if lines else ""

    def close(self):
        try:
            self.proc.stdin.close()
        except (OSError, ValueError):
            pass
        try:
            self.proc.wait(3)
        except subprocess.TimeoutExpired:
            self.proc.kill()


class LocalTransport:
    """An MCP server object in this process (FakeStudio): each message handed to its handle(), its answers back
    from a thread of their own, as from a process."""

    def __init__(self, server):
        self.server = server
        self.on_message = lambda msg: None
        self.on_close = lambda why: None
        self.cmd = ["(in process)", type(server).__name__]

    def start(self):
        pass

    def send(self, msg):
        def answer():
            out = self.server.handle(msg)
            if out is not None:
                self.on_message(out)
        threading.Thread(target=answer, name="studio-fake", daemon=True).start()

    def tail(self):
        return ""

    def close(self):
        self.on_close("closed")


# -- the client ----------------------------------------------------------------------------------------------------

class McpClient:
    """An MCP client over a transport: initialize, then requests (tools/list, tools/call) answered by id, each with a
    timeout. A request the server sends us (ping) is answered; notifications are ignored."""

    def __init__(self, transport, timeout=TIMEOUT):
        self.transport = transport
        self.timeout = timeout
        self._ids = itertools.count(1)
        self._pending = {}  # id -> [threading.Event, message or None]
        self._lock = threading.Lock()
        self.closed = None
        self.server_info = {}
        self.tools = {}  # name -> its tools/list entry ({"name", "description", "inputSchema"})
        transport.on_message = self._on_message
        transport.on_close = self._on_close

    def start(self, timeout=START_TIMEOUT):
        """Initialize (the server says who it is) and list its tools. Returns self."""
        self.transport.start()
        init = self.request("initialize", {
            "protocolVersion": PROTOCOL_VERSION, "capabilities": {},
            "clientInfo": {"name": "autopilot-roblox", "version": getattr(autopilot, "__version__", "0")}},
            timeout=timeout)
        self.server_info = init or {}
        self.notify("notifications/initialized")
        self.tools = {t["name"]: t for t in self.list_tools() if isinstance(t, dict) and t.get("name")}
        return self

    def request(self, method, params=None, timeout=None):
        if self.closed:
            raise McpError(f"the Roblox Studio MCP server is gone ({self.closed})")
        rid = next(self._ids)
        entry = [threading.Event(), None]
        with self._lock:
            self._pending[rid] = entry
        try:
            msg = {"jsonrpc": "2.0", "id": rid, "method": method}
            if params is not None:
                msg["params"] = params
            self.transport.send(msg)
            timeout = self.timeout if timeout is None else timeout
            if not entry[0].wait(timeout):
                # (tell the server we stopped waiting: MCP's cancellation)
                try:
                    self.notify("notifications/cancelled", {"requestId": rid, "reason": "timeout"})
                except McpError:
                    pass
                raise McpTimeout(f"the Roblox Studio MCP server didn't answer {method} within {timeout:g}s")
        finally:
            with self._lock:
                self._pending.pop(rid, None)
        answer = entry[1]
        if answer is None:
            raise McpError(f"the Roblox Studio MCP server is gone ({self.closed}){self.transport.tail()}")
        if "error" in answer:
            err = answer.get("error") or {}
            raise McpError(f"{method}: {err.get('message') or err}", code=err.get("code"))
        return answer.get("result")

    def notify(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        self.transport.send(msg)

    def list_tools(self):
        tools, cursor = [], None
        for _ in range(50):  # (pages)
            r = self.request("tools/list", {"cursor": cursor} if cursor else {}) or {}
            tools += r.get("tools") or []
            cursor = r.get("nextCursor")
            if not cursor:
                break
        return tools

    def call_tool(self, name, arguments=None, timeout=None):
        """A tool's result ({"content": [...], "structuredContent"?, "isError"?}). Raises ToolError when the tool says
        it failed."""
        r = self.request("tools/call", {"name": name, "arguments": arguments or {}}, timeout=timeout) or {}
        if r.get("isError"):
            raise ToolError(f"{name}: {text_of(r) or 'failed'}")
        return r

    def _on_message(self, msg):
        if "id" in msg and ("result" in msg or "error" in msg) and "method" not in msg:
            with self._lock:
                entry = self._pending.get(msg.get("id"))
            if entry:
                entry[1] = msg
                entry[0].set()
            return
        if "id" in msg and "method" in msg:  # (the server asks us something)
            if msg["method"] == "ping":
                reply = {"jsonrpc": "2.0", "id": msg["id"], "result": {}}
            else:
                reply = {"jsonrpc": "2.0", "id": msg["id"],
                         "error": {"code": -32601, "message": f"method not found: {msg['method']}"}}
            try:
                self.transport.send(reply)
            except McpError:
                pass

    def _on_close(self, why):
        self.closed = why or "closed"
        with self._lock:
            pending = list(self._pending.values())
        for entry in pending:
            entry[0].set()

    def close(self):
        self.transport.close()


def text_of(result):
    """The text a tool's result carries: its text content joined, else its structured content as JSON."""
    if not isinstance(result, dict):
        return "" if result is None else str(result)
    parts = [c.get("text") or "" for c in result.get("content") or []
             if isinstance(c, dict) and c.get("type") == "text"]
    if parts:
        return "\n".join(parts)
    if result.get("structuredContent") is not None:
        return json.dumps(result["structuredContent"])
    return ""


def image_of(result):
    """(bytes, mime type) of the first image a tool's result carries, or (None, None)."""
    for c in (result or {}).get("content") or []:
        if isinstance(c, dict) and c.get("type") == "image" and c.get("data"):
            return base64.b64decode(c["data"]), c.get("mimeType") or "image/png"
    return None, None


# -- the tools, as the engine uses them ------------------------------------------------------------------------------

class Studio:
    """The Studio tools over an McpClient, each with the arguments its schema names (see ARGS)."""

    def __init__(self, client, studio_id=None):
        self.client = client
        self.studio_id = studio_id or (os.environ.get(ENV_STUDIO_ID) or "").strip() or None

    @classmethod
    def connect(cls, transport=None, timeout=TIMEOUT):
        """A Studio over the server's process (command()), or over the transport given; initialized and checked
        (check())."""
        transport = transport or StdioTransport(command())
        client = McpClient(transport, timeout=timeout)
        try:
            client.start()
            studio = cls(client)
            studio.check()
        except Exception:
            client.close()
            raise
        return studio

    @property
    def tools(self):
        return self.client.tools

    def has(self, name):
        return name in self.client.tools

    def missing(self):
        return [t for t in REQUIRED if not self.has(t)]

    def check(self):
        """Raise ToolMissing, saying what to do, when the server lacks a tool the engine needs; pick the Studio when
        the server is connected to several. Returns the optional tools missing, with what each lack costs."""
        missing = self.missing()
        if missing:
            offered = ", ".join(sorted(self.client.tools)) or "none"
            who = (self.client.server_info.get("serverInfo") or {}).get("name") or "the server"
            raise ToolMissing(
                f"The Roblox Studio MCP server ({who}, started with: {' '.join(self.client.transport.cmd)}) doesn't "
                f"offer {', '.join(missing)}, which Autopilot needs. It offers: {offered}. Use Studio's built-in MCP "
                "server: in Roblox Studio, open Assistant, then ... > Manage MCP Servers, and turn on 'Enable Studio "
                f"as MCP server'; update Studio if the option isn't there. If {ENV_CMD} is set, check it starts that "
                "server. (If the server names these tools otherwise, the names are in "
                "autopilot/engines/roblox_mcp.py.)")
        if self.studio_id is None and self.needs_studio_id():
            self.studio_id = self.pick_studio()
        return {t: why for t, why in OPTIONAL.items()
                if not self.has(t) and (t != LIST_ROBLOX_STUDIOS or self.needs_studio_id())}

    def needs_studio_id(self):
        schema = (self.client.tools.get(EXECUTE_LUAU) or {}).get("inputSchema") or {}
        return "studio_id" in (schema.get("required") or [])

    def pick_studio(self):
        """The one Studio the server is connected to (list_roblox_studios); several: AUTOPILOT_ROBLOX_STUDIO_ID must
        say which."""
        if not self.has(LIST_ROBLOX_STUDIOS):
            return None
        found = parse_json(text_of(self.call(LIST_ROBLOX_STUDIOS, {})))
        studios = found if isinstance(found, list) else (found or {}).get("studios") if isinstance(found, dict) else []
        studios = [s for s in studios or [] if isinstance(s, dict)]
        ids = [str(s.get("studio_id") or s.get("id") or s.get("studioId") or "") for s in studios]  # TODO(verify)
        ids = [i for i in ids if i]
        if len(ids) == 1:
            return ids[0]
        if not ids:
            raise McpError("Roblox Studio isn't connected to its MCP server: open the place in Studio first")
        raise McpError(f"the MCP server is connected to {len(ids)} Studios ({', '.join(ids)}): set {ENV_STUDIO_ID} "
                       "to the one to play")

    def arg(self, tool, meaning):
        """The name `tool` takes for an argument meaning `meaning` (see ARGS)."""
        names = ARGS[tool][meaning]
        props = ((self.client.tools.get(tool) or {}).get("inputSchema") or {}).get("properties") or {}
        return next((n for n in names if n in props), names[0])

    def call(self, tool, arguments, timeout=None):
        if not self.has(tool):
            raise ToolMissing(f"the Roblox Studio MCP server has no {tool} tool ({OPTIONAL.get(tool, 'needed')})")
        args = dict(arguments)
        if self.studio_id is not None:
            args.setdefault("studio_id", self.studio_id)
        return self.client.call_tool(tool, args, timeout=timeout)

    # -- each tool ----------------------------------------------------------------------------------------------

    def execute_luau(self, code, datamodel="Edit", timeout=None):
        """Run Luau in a data model (Edit, Client or Server); the tool's whole text result."""
        return text_of(self.call(EXECUTE_LUAU, {self.arg(EXECUTE_LUAU, "code"): code,
                                                self.arg(EXECUTE_LUAU, "datamodel"): datamodel}, timeout=timeout))

    def start_stop_play(self, start, timeout=60):
        name = self.arg(START_STOP_PLAY, "start")
        schema = ((self.tools.get(START_STOP_PLAY) or {}).get("inputSchema") or {}).get("properties") or {}
        kind = (schema.get(name) or {}).get("type")
        if name in ("is_start", "start") or kind == "boolean":
            value = bool(start)
        else:  # (a mode string: the open-source studio-rust-mcp-server's "start_play" / "stop")  TODO(verify)
            value = "start_play" if start else "stop"
        return text_of(self.call(START_STOP_PLAY, {name: value}, timeout=timeout))

    def studio_state(self):
        """What get_studio_state says (parsed JSON when it is JSON, else its text), or None without the tool."""
        if not self.has(GET_STUDIO_STATE):
            return None
        text = text_of(self.call(GET_STUDIO_STATE, {}))
        parsed = parse_json(text)
        return parsed if parsed is not None else text

    def console_output(self):
        """get_console_output's text."""
        return text_of(self.call(GET_CONSOLE_OUTPUT, {}))

    def screen_capture(self, timeout=20):
        """(bytes, mime) of the viewport, or (None, None) when the result has no image."""
        return image_of(self.call(SCREEN_CAPTURE, {}, timeout=timeout))

    def search_game_tree(self, path=None, instance_type=None, keywords=None, depth=None, timeout=60):
        args = {}
        for meaning, value in (("path", path), ("type", instance_type), ("keywords", keywords), ("depth", depth)):
            if value is not None:
                args[self.arg(SEARCH_GAME_TREE, meaning)] = value
        return text_of(self.call(SEARCH_GAME_TREE, args, timeout=timeout))

    def inspect_instance(self, path):
        return text_of(self.call(INSPECT_INSTANCE, {self.arg(INSPECT_INSTANCE, "path"): path}))

    def script_read(self, path, timeout=30):
        """A script's source by its dot path (game.ServerScriptService.Main). TODO(verify): whether the result has line
        numbers in front of each line (they are taken off when every line has one)."""
        return strip_line_numbers(text_of(self.call(SCRIPT_READ, {self.arg(SCRIPT_READ, "path"): path},
                                                    timeout=timeout)))

    def script_grep(self, pattern):
        return text_of(self.call(SCRIPT_GREP, {self.arg(SCRIPT_GREP, "pattern"): pattern}))

    def keyboard(self, actions, datamodel="Client"):
        """Ordered keyboard actions: [{"type": "key_down"|"key_up"|"key_press"|"text"|"wait", "key"?, "text"?,
        "seconds"?}] (key: a Roblox KeyCode name). TODO(verify) the action shape against the live schema."""
        return text_of(self.call(USER_KEYBOARD_INPUT, {self.arg(USER_KEYBOARD_INPUT, "actions"): actions,
                                                      self.arg(USER_KEYBOARD_INPUT, "datamodel"): datamodel}))

    def mouse(self, actions, datamodel="Client"):
        """Ordered mouse actions: [{"type": "move"|"click"|"button_down"|"button_up"|"scroll"|"wait", "x"?, "y"?
        (viewport pixels from the top left), "button"? ("left"/"right"/"middle"), "instance_path"?}]. TODO(verify) the
        action shape against the live schema."""
        return text_of(self.call(USER_MOUSE_INPUT, {self.arg(USER_MOUSE_INPUT, "actions"): actions,
                                                   self.arg(USER_MOUSE_INPUT, "datamodel"): datamodel}))

    def navigate(self, position=None, instance=None, speed=None, timeout=60):
        """Walk the player's character to a position ({"x","y","z"} studs) or an instance (a dot path)."""
        args = {}
        if position is not None:
            args[self.arg(CHARACTER_NAVIGATION, "position")] = position  # TODO(verify): an object or [x, y, z]?
        if instance is not None:
            args[self.arg(CHARACTER_NAVIGATION, "instance")] = instance
        if speed is not None:
            args[self.arg(CHARACTER_NAVIGATION, "speed")] = speed
        return text_of(self.call(CHARACTER_NAVIGATION, args, timeout=timeout))

    def close(self):
        self.client.close()


def parse_json(text):
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return None


def strip_line_numbers(text):
    """A script_read text without line numbers in front of its lines ("12: x" / "12\tx" / "  12 | x"), when every
    non-empty line has one counting up from the first."""
    import re

    lines = text.split("\n")
    pat = re.compile(r"^\s*(\d+)\s*(?:[:|\t]\s?|\s)(.*)$")
    out, expect = [], None
    for line in lines:
        if not line.strip():  # (an empty line, numbered or not)
            out.append("")
            if expect is not None:
                expect += 1
            continue
        m0 = re.match(r"^\s*(\d+)\s*[:|\t]?\s*$", line)
        if m0 and (expect is None or int(m0.group(1)) == expect):  # (a numbered empty line)
            out.append("")
            expect = int(m0.group(1)) + 1
            continue
        m = pat.match(line)
        if not m or (expect is not None and int(m.group(1)) != expect):
            return text
        expect = int(m.group(1)) + 1
        out.append(m.group(2))
    return "\n".join(out) if expect is not None else text


def dot_path(path):
    """An engine path (Workspace/Level/Door, see roblox.luau) as Studio's dot path (game.Workspace.Level.Door), for
    the tools that take one. A same-named sibling's index (Coin@2) has no dot form: it is dropped."""
    import re

    parts = [re.sub(r"(?<!\\)@\d+$", "", p).replace("\\/", "/").replace("\\@", "@").replace("\\\\", "\\")
             for p in re.split(r"(?<!\\)/", path)]
    return "game." + ".".join(parts)


# -- a stand-in for Studio's server (tests, tools/roblox_latency.py --fake) -------------------------------------------

# The tools FakeStudio offers, with the argument names it advertises (the first guesses in ARGS)
FAKE_SCHEMAS = {
    EXECUTE_LUAU: {"code": {"type": "string"}, "datamodel_type": {"type": "string", "enum": list(DATAMODELS)}},
    START_STOP_PLAY: {"is_start": {"type": "boolean"}},
    GET_CONSOLE_OUTPUT: {},
    GET_STUDIO_STATE: {},
    SCREEN_CAPTURE: {},
    SEARCH_GAME_TREE: {"path": {"type": "string"}, "instance_type": {"type": "string"},
                       "max_depth": {"type": "integer"}},
    INSPECT_INSTANCE: {"path": {"type": "string"}},
    SCRIPT_READ: {"path": {"type": "string"}},
    SCRIPT_GREP: {"pattern": {"type": "string"}},
    USER_KEYBOARD_INPUT: {"actions": {"type": "array"}, "datamodel_type": {"type": "string"}},
    USER_MOUSE_INPUT: {"actions": {"type": "array"}, "datamodel_type": {"type": "string"}},
    CHARACTER_NAVIGATION: {"target_position": {"type": "object"}, "instance_path": {"type": "string"},
                           "speed_multiplier": {"type": "number"}},
}


class FakeStudio:
    """An MCP server that stands in for StudioMCP: initialize, tools/list (FAKE_SCHEMAS, less `without`) and
    tools/call, answered by handlers (name -> fn(arguments) returning a tools/call result, a string (its text) or
    bytes (a PNG)). Every call is kept in `calls`. Without a handler a tool answers "ok"; execute_luau's default
    answers what tests/robloxsim.py's place would not: an empty batch. serve_stdio() speaks MCP's stdio transport."""

    def __init__(self, handlers=None, without=(), schemas=None, name="FakeStudio"):
        self.handlers = dict(handlers or {})
        self.schemas = {k: v for k, v in (schemas or FAKE_SCHEMAS).items() if k not in set(without)}
        self.name = name
        self.calls = []
        self.lock = threading.Lock()
        self.initialized = False

    def tool_list(self):
        return [{"name": n, "description": f"(fake) {n}",
                 "inputSchema": {"type": "object", "properties": props}} for n, props in self.schemas.items()]

    def handle(self, msg):
        method, rid = msg.get("method"), msg.get("id")
        if rid is None:  # (a notification)
            if method == "notifications/initialized":
                self.initialized = True
            return None
        try:
            if method == "initialize":
                result = {"protocolVersion": (msg.get("params") or {}).get("protocolVersion", PROTOCOL_VERSION),
                          "capabilities": {"tools": {"listChanged": False}},
                          "serverInfo": {"name": self.name, "version": "0"}}
            elif method == "tools/list":
                result = {"tools": self.tool_list()}
            elif method == "tools/call":
                params = msg.get("params") or {}
                name, args = params.get("name"), params.get("arguments") or {}
                if name not in self.schemas:
                    return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": f"unknown tool {name}"}}
                with self.lock:
                    self.calls.append((name, args))
                result = self._result(self.handlers.get(name, self._default(name))(args))
            elif method == "ping":
                result = {}
            else:
                return {"jsonrpc": "2.0", "id": rid,
                        "error": {"code": -32601, "message": f"method not found: {method}"}}
        except Exception as e:  # (a handler's failure is the tool's)
            result = {"content": [{"type": "text", "text": f"{type(e).__name__}: {e}"}], "isError": True}
        return {"jsonrpc": "2.0", "id": rid, "result": result}

    @staticmethod
    def _result(out):
        if isinstance(out, dict) and "content" in out:
            return out
        if isinstance(out, (bytes, bytearray)):
            return {"content": [{"type": "image", "data": base64.b64encode(bytes(out)).decode("ascii"),
                                 "mimeType": "image/png"}]}
        return {"content": [{"type": "text", "text": out if isinstance(out, str) else json.dumps(out)}]}

    def _default(self, name):
        if name == EXECUTE_LUAU:
            def run(args):
                code = str(args.get("code") or "")
                if "--fake-sleep:" in code:  # (a slow call, for the client's timeout)
                    time.sleep(float(code.split("--fake-sleep:", 1)[1].split()[0]))
                return json.dumps({"t": 0.0, "r": []})
            return run
        return lambda args: "ok"

    def count(self, name):
        with self.lock:
            return sum(1 for n, _ in self.calls if n == name)

    def serve_stdio(self, stdin=None, stdout=None):
        """Answer MCP over stdio (a line a message) until stdin ends."""
        stdin = stdin or sys.stdin.buffer
        stdout = stdout or sys.stdout.buffer
        for raw in stdin:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            out = self.handle(msg)
            if out is not None:
                stdout.write((json.dumps(out) + "\n").encode("utf-8"))
                stdout.flush()


def main(argv=None):
    """`python -m autopilot.engines.roblox_mcp --fake [--without tool,tool]`: FakeStudio on stdio (for the client's
    tests, and for trying the engine's plumbing without Studio)."""
    import argparse

    ap = argparse.ArgumentParser(description=main.__doc__)
    ap.add_argument("--fake", action="store_true", required=True)
    ap.add_argument("--without", default="", help="tools left out, comma-separated")
    ap.add_argument("--noise", action="store_true", help="also write a log line and a notification on stdout")
    args = ap.parse_args(argv)
    if args.noise:
        sys.stdout.write("StudioMCP fake starting (a log line, not JSON)\n")
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/message",
                                     "params": {"level": "info", "data": "hello"}}) + "\n")
        sys.stdout.flush()
    FakeStudio(without=[t for t in args.without.split(",") if t]).serve_stdio()


if __name__ == "__main__":
    main()

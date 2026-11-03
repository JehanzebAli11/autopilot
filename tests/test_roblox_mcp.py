"""The Roblox Studio MCP client (autopilot/engines/roblox_mcp.py) against FakeStudio, no Studio: JSON-RPC framing over
stdio (a real child process) and in process, tool discovery and its error, argument names taken from the tools'
schemas, timeouts, and the server's command from the environment."""

import json
import os
import subprocess
import sys
import threading

import pytest

from autopilot.engines import roblox_mcp as mcp


def fake_process(*extra):
    """FakeStudio as a child process on stdio, as Studio's own server runs."""
    return mcp.StdioTransport([sys.executable, "-u", "-m", "autopilot.engines.roblox_mcp", "--fake", *extra])


# -- framing -------------------------------------------------------------------------------------------------------

def test_the_client_speaks_json_rpc_over_stdio_to_a_server_process():
    client = mcp.McpClient(fake_process("--noise"), timeout=20).start()
    try:
        assert client.server_info["serverInfo"]["name"] == "FakeStudio"
        assert client.server_info["protocolVersion"] == mcp.PROTOCOL_VERSION
        assert set(mcp.REQUIRED) <= set(client.tools)
        assert client.tools[mcp.EXECUTE_LUAU]["inputSchema"]["properties"]["datamodel_type"]["enum"] == \
            ["Edit", "Client", "Server"]
        r = client.call_tool(mcp.EXECUTE_LUAU, {"code": "return 1", "datamodel_type": "Edit"})
        assert json.loads(mcp.text_of(r)) == {"t": 0.0, "r": []}
        # (requests answered out of order still find their callers: by id)
        out = [None] * 6

        def call(i):
            out[i] = mcp.text_of(client.call_tool(mcp.GET_CONSOLE_OUTPUT, {}))

        threads = [threading.Thread(target=call, args=(i,)) for i in range(6)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(20)
        assert out == ["ok"] * 6
        with pytest.raises(mcp.McpError, match="unknown tool"):
            client.call_tool("no_such_tool", {})
    finally:
        client.close()


def test_the_framing_is_one_json_message_a_line():
    """What the client writes is what MCP's stdio transport says: one JSON-RPC object per line, ids counting up, the
    initialized notification without an id; a log line or a notification on the server's stdout is no answer."""
    written = []

    class Recorder:
        cmd = ["recorder"]

        def start(self):
            pass

        def send(self, msg):
            written.append(json.dumps(msg))
            server = mcp.FakeStudio()
            out = server.handle(msg)
            if msg.get("method") == "initialize":
                self.on_message({"jsonrpc": "2.0", "method": "notifications/message", "params": {"data": "x"}})
            if out is not None:
                self.on_message(out)

        def tail(self):
            return ""

        def close(self):
            pass

    client = mcp.McpClient(Recorder()).start()
    msgs = [json.loads(line) for line in written]
    assert all("\n" not in line for line in written)
    assert [m.get("method") for m in msgs] == ["initialize", "notifications/initialized", "tools/list"]
    assert msgs[0]["jsonrpc"] == "2.0" and msgs[0]["id"] == 1 and msgs[2]["id"] == 2 and "id" not in msgs[1]
    assert msgs[0]["params"]["clientInfo"]["name"] == "autopilot-roblox"
    assert mcp.EXECUTE_LUAU in client.tools


def test_a_server_that_doesnt_answer_times_out_and_is_told():
    server = mcp.FakeStudio()
    client = mcp.McpClient(mcp.LocalTransport(server), timeout=0.3).start()
    with pytest.raises(mcp.McpTimeout, match="didn't answer tools/call within 0.3s"):
        client.call_tool(mcp.EXECUTE_LUAU, {"code": "--fake-sleep:2", "datamodel_type": "Edit"})
    # (the next call is answered normally)
    assert json.loads(mcp.text_of(client.call_tool(mcp.EXECUTE_LUAU, {"code": "1", "datamodel_type": "Edit"})))


def test_a_server_that_ends_fails_the_calls_waiting():
    transport = fake_process()
    client = mcp.McpClient(transport, timeout=20).start()
    transport.proc.kill()
    transport.proc.wait(10)
    with pytest.raises(mcp.McpError, match="gone"):
        for _ in range(50):  # (until the reader has seen the end)
            client.call_tool(mcp.GET_CONSOLE_OUTPUT, {})


def test_a_tool_error_is_raised_with_its_text():
    def boom(args):
        return {"content": [{"type": "text", "text": "Script error: attempt to index nil"}], "isError": True}

    client = mcp.McpClient(mcp.LocalTransport(mcp.FakeStudio({mcp.EXECUTE_LUAU: boom}))).start()
    with pytest.raises(mcp.ToolError, match="attempt to index nil"):
        client.call_tool(mcp.EXECUTE_LUAU, {})


def test_the_client_answers_the_servers_ping():
    sent = []

    class T:
        cmd = ["t"]

        def start(self):
            pass

        def send(self, msg):
            sent.append(msg)

        def tail(self):
            return ""

        def close(self):
            pass

    client = mcp.McpClient(T())
    client._on_message({"jsonrpc": "2.0", "id": 7, "method": "ping"})
    client._on_message({"jsonrpc": "2.0", "id": 8, "method": "sampling/createMessage"})
    assert sent[0] == {"jsonrpc": "2.0", "id": 7, "result": {}}
    assert sent[1]["id"] == 8 and sent[1]["error"]["code"] == -32601


# -- tool discovery --------------------------------------------------------------------------------------------

def test_a_missing_required_tool_fails_with_what_to_do():
    with pytest.raises(mcp.ToolMissing) as e:
        mcp.Studio.connect(mcp.LocalTransport(mcp.FakeStudio(without=[mcp.EXECUTE_LUAU, mcp.START_STOP_PLAY])))
    text = str(e.value)
    assert "doesn't offer execute_luau, start_stop_play" in text
    assert "Manage MCP Servers" in text and "Enable Studio as MCP server" in text
    assert mcp.ENV_CMD in text and "get_console_output" in text  # (what it does offer)


def test_missing_optional_tools_are_said_and_their_calls_refused():
    studio = mcp.Studio.connect(mcp.LocalTransport(mcp.FakeStudio(without=[mcp.SCREEN_CAPTURE,
                                                                           mcp.CHARACTER_NAVIGATION])))
    lacking = studio.check()
    assert set(lacking) == {mcp.SCREEN_CAPTURE, mcp.CHARACTER_NAVIGATION}
    assert "no pictures" in lacking[mcp.SCREEN_CAPTURE]
    with pytest.raises(mcp.ToolMissing, match="no screen_capture tool"):
        studio.screen_capture()


def test_the_client_discovers_tools_over_pages():
    server = mcp.FakeStudio()
    tools = server.tool_list()
    real = server.handle

    def paged(msg):
        if msg.get("method") == "tools/list":
            cursor = (msg.get("params") or {}).get("cursor")
            half = len(tools) // 2
            page = tools[half:] if cursor else tools[:half]
            more = {} if cursor else {"nextCursor": "2"}
            return {"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": page, **more}}
        return real(msg)

    server.handle = paged
    client = mcp.McpClient(mcp.LocalTransport(server)).start()
    assert set(client.tools) == {t["name"] for t in tools}


# -- argument names --------------------------------------------------------------------------------------------

def test_arguments_follow_the_names_each_tool_advertises():
    """A server whose schemas name the arguments otherwise (as the open-source studio-rust-mcp-server's run_code
    `command` and start_stop_play `mode` do) gets them by those names."""
    schemas = dict(mcp.FAKE_SCHEMAS)
    schemas[mcp.EXECUTE_LUAU] = {"command": {"type": "string"}, "context": {"type": "string"}}
    schemas[mcp.START_STOP_PLAY] = {"mode": {"type": "string"}}
    server = mcp.FakeStudio(schemas=schemas)
    studio = mcp.Studio.connect(mcp.LocalTransport(server))
    studio.execute_luau("print(1)", datamodel="Server")
    studio.start_stop_play(True)
    studio.start_stop_play(False)
    assert server.calls[0] == (mcp.EXECUTE_LUAU, {"command": "print(1)", "context": "Server"})
    assert [c[1] for c in server.calls[1:]] == [{"mode": "start_play"}, {"mode": "stop"}]
    # (the documented names, when the schema has them)
    server = mcp.FakeStudio()
    studio = mcp.Studio.connect(mcp.LocalTransport(server))
    studio.execute_luau("x", datamodel="Client")
    studio.start_stop_play(True)
    studio.keyboard([mcp.key_action("press", "E")])
    studio.navigate(position={"x": 1, "y": 2, "z": 3})
    assert server.calls == [(mcp.EXECUTE_LUAU, {"code": "x", "datamodel_type": "Client"}),
                            (mcp.START_STOP_PLAY, {"is_start": True}),
                            (mcp.USER_KEYBOARD_INPUT, {"actions": [{"type": "key_press", "key": "E"}],
                                                       "datamodel_type": "Client"}),
                            (mcp.CHARACTER_NAVIGATION, {"target_position": {"x": 1, "y": 2, "z": 3}})]


def test_a_studio_id_is_passed_when_the_server_needs_one(monkeypatch):
    monkeypatch.delenv(mcp.ENV_STUDIO_ID, raising=False)
    schemas = {k: dict(v) for k, v in mcp.FAKE_SCHEMAS.items()}
    schemas[mcp.LIST_ROBLOX_STUDIOS] = {}
    server = mcp.FakeStudio({mcp.LIST_ROBLOX_STUDIOS: lambda a: json.dumps([{"studio_id": "abc", "name": "P"}])},
                            schemas=schemas)
    real = server.tool_list
    server.tool_list = lambda: [dict(t, inputSchema=dict(t["inputSchema"], required=["studio_id"])) for t in real()]
    studio = mcp.Studio.connect(mcp.LocalTransport(server))
    assert studio.studio_id == "abc"
    studio.execute_luau("1")
    assert server.calls[-1][1]["studio_id"] == "abc"
    # two Studios: the user says which
    server.handlers[mcp.LIST_ROBLOX_STUDIOS] = lambda a: json.dumps([{"studio_id": "a"}, {"studio_id": "b"}])
    with pytest.raises(mcp.McpError, match=mcp.ENV_STUDIO_ID):
        mcp.Studio.connect(mcp.LocalTransport(server))


def test_results_text_images_and_line_numbers():
    assert mcp.text_of({"content": [{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]}) == "a\nb"
    assert mcp.text_of({"content": [], "structuredContent": {"x": 1}}) == '{"x": 1}'
    data, mime = mcp.image_of({"content": [{"type": "image", "data": "aGk=", "mimeType": "image/png"}]})
    assert data == b"hi" and mime == "image/png"
    assert mcp.strip_line_numbers("1: local x = 1\n2: return x") == "local x = 1\nreturn x"
    assert mcp.strip_line_numbers("  1\tlocal x\n\n  3\tend") == "local x\n\nend"
    assert mcp.strip_line_numbers("local a = 1\nreturn a") == "local a = 1\nreturn a"  # (no numbers: as it is)
    assert mcp.strip_line_numbers("10 apples\n3 pears") == "10 apples\n3 pears"  # (not counting up: text)
    assert mcp.dot_path("Workspace/Obby/Stage") == "game.Workspace.Obby.Stage"
    assert mcp.dot_path("Workspace/Coin@2") == "game.Workspace.Coin"


# -- the server's command ----------------------------------------------------------------------------------------

def test_the_server_command_comes_from_the_environment():
    if os.name != "nt":  # (Windows' command lines keep their quotes: shlex's non-POSIX rules)
        assert mcp.command({mcp.ENV_CMD: "studio-mcp --flag 'a b'"}) == ["studio-mcp", "--flag", "a b"]
    win = mcp.default_command("win32", {"LOCALAPPDATA": r"C:\Users\me\AppData\Local"})
    assert win[:2] == ["cmd.exe", "/c"] and win[2].endswith("mcp.bat") and "Roblox" in win[2]
    moved = mcp.default_command("win32", {"LOCALAPPDATA": r"C:\bench\settings",
                                          mcp.ENV_LOCALAPPDATA: r"C:\Users\me\AppData\Local"})
    assert moved[2].startswith(r"C:\Users\me")  # (the bench moves LOCALAPPDATA: Studio's file is in the real one)
    assert mcp.default_command("darwin", {}) == ["/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP"]
    assert mcp.default_command("linux", {}) is None
    if sys.platform.startswith("linux"):
        with pytest.raises(mcp.McpError, match=mcp.ENV_CMD):
            mcp.command({})
    assert mcp.spawn_env({mcp.ENV_LOCALAPPDATA: "real", "LOCALAPPDATA": "moved"})["LOCALAPPDATA"] == "real"


def test_a_command_that_cant_start_says_so():
    with pytest.raises(mcp.McpError, match="couldn't start the Roblox Studio MCP server"):
        mcp.StdioTransport(["/nonexistent/StudioMCP"])


def test_the_fake_runs_as_a_module():
    p = subprocess.run([sys.executable, "-m", "autopilot.engines.roblox_mcp", "--fake"],
                       input=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}) + "\n",
                       capture_output=True, text=True, timeout=60)
    names = {t["name"] for t in json.loads(p.stdout.strip())["result"]["tools"]}
    assert set(mcp.REQUIRED) <= names


# Test fixtures

## playwright-mcp-0.0.82-tools-list.json

The recorded `tools/list` reply of `@playwright/mcp`, version **0.0.82**. It is the pinned
version in `release/playwright-pins/pins.json` (`mcp.version`). Two test suites read it:

- `Tests/InstanceMCPCoreTests/ToolSchemaShapeTests.swift` (Swift)
- `poc/reverse-attach-linux/src/tool_schema_shape_tests.rs` (Rust, via `include_str!`)

Both expect **32 tools** and check that `browser_emulate_media` is served as option B.

File shape: a JSON object with a `source` string (what the capture was) and a `result` object.
`result` is the `result` member of the JSON-RPC reply, so it has `tools`. There is no `jsonrpc`
or `id` member.

### How to re-record

Capture over stdio from a fresh process. Do not use the running service, and do not pass
`--port`, `--host` or `--allowed-hosts`: the capture needs no network port.

1. Make a scratch directory and copy the pinned package files into it. Do not edit them.

   ```sh
   mkdir -p /tmp/pw-mcp-capture && cd /tmp/pw-mcp-capture
   cp <repo>/release/playwright-pins/package.json <repo>/release/playwright-pins/package-lock.json .
   ```

2. Install exactly the locked tree. This is the install `scripts/playwright-pins.py` uses, without
   install scripts:

   ```sh
   npm ci --ignore-scripts --omit=dev --no-audit --no-fund --registry https://registry.npmjs.org/
   ```

3. Launch the server over stdio with the flags named in the fixture's `source` field:
   `--browser chromium --shared-browser-context --caps vision,pdf --headless`. The entry point is
   `node_modules/@playwright/mcp/cli.js`.

4. Send three newline-delimited JSON-RPC messages on stdin, then read stdout until the reply with
   `id` 2 arrives:

   ```json
   {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"capture","version":"0"}}}
   {"jsonrpc":"2.0","method":"notifications/initialized"}
   {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
   ```

5. Write `{"source": "<text>", "result": <the reply's result>}` to
   `Tests/Fixtures/playwright-mcp-0.0.82-tools-list.json`, pretty-printed with two-space indent and a
   final newline. Set `source` to the same kind of note as the current file: the package version,
   the flags, "stdio tools/list", and "a fresh process, not the running service".

   A minimal Node capture script that does steps 3 to 5 and checks the count:

   ```js
   // Run from /tmp/pw-mcp-capture: node capture.mjs <repo>/Tests/Fixtures/playwright-mcp-0.0.82-tools-list.json
   import { spawn } from "node:child_process";
   import { createInterface } from "node:readline";
   import { writeFileSync } from "node:fs";

   const out = process.argv[2];
   const child = spawn("node", ["node_modules/@playwright/mcp/cli.js", "--browser", "chromium",
     "--shared-browser-context", "--caps", "vision,pdf", "--headless"],
     { stdio: ["pipe", "pipe", "inherit"] });
   const send = (m) => child.stdin.write(JSON.stringify(m) + "\n");
   createInterface({ input: child.stdout }).on("line", (line) => {
     let m;
     try { m = JSON.parse(line); } catch { return; }
     if (m.id === 1) {
       send({ jsonrpc: "2.0", method: "notifications/initialized" });
       send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
     }
     if (m.id === 2) {
       const tools = m.result?.tools ?? [];
       if (tools.length !== 32) { console.error(`expected 32 tools, got ${tools.length}`); process.exit(1); }
       writeFileSync(out, JSON.stringify({ source: "@playwright/mcp@0.0.82 stdio tools/list, flags as ManagedPlaywright (--browser chromium --shared-browser-context --caps vision,pdf --headless); a fresh process, not the running service", result: m.result }, null, 2) + "\n");
       child.kill();
     }
   });
   send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "capture", version: "0" } } });
   ```

6. Run the Swift and Rust suites on the test hosts. They must pass with the new file.

### When to re-record

- The pinned version in `release/playwright-pins/pins.json` changes. Re-record, then update the
  tool count (`32`) in both suites if the number of tools changed.
- Do not edit the JSON by hand. Re-record from the pinned package.

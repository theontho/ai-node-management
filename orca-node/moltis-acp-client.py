#!/usr/bin/env python3
"""Run one Moltis prompt through its Agent Client Protocol stdio server."""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
from typing import TextIO


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--moltis-binary", type=pathlib.Path, required=True)
    parser.add_argument("--config-dir", type=pathlib.Path, required=True)
    parser.add_argument("--data-dir", type=pathlib.Path, required=True)
    parser.add_argument("--cwd", type=pathlib.Path, required=True)
    parser.add_argument("--prompt", required=True)
    return parser.parse_args()


def send(stream: TextIO, message: dict[str, object]) -> None:
    stream.write(json.dumps(message, separators=(",", ":")) + "\n")
    stream.flush()


def read_response(
    incoming: TextIO,
    outgoing: TextIO,
    request_id: int,
) -> dict[str, object]:
    while line := incoming.readline():
        message = json.loads(line)
        if message.get("id") == request_id:
            if "error" in message:
                raise RuntimeError(f"ACP request {request_id} failed: {message['error']}")
            result = message.get("result")
            if not isinstance(result, dict):
                raise RuntimeError(
                    f"ACP request {request_id} returned an invalid result: {result!r}"
                )
            return result

        method = message.get("method")
        if method == "session/update":
            params = message.get("params")
            if isinstance(params, dict):
                update = params.get("update")
                if isinstance(update, dict):
                    content = update.get("content")
                    if isinstance(content, dict) and content.get("type") == "text":
                        text = content.get("text")
                        if isinstance(text, str):
                            print(text, end="", flush=True)
            continue

        if "id" in message and isinstance(method, str):
            send(
                outgoing,
                {
                    "jsonrpc": "2.0",
                    "id": message["id"],
                    "error": {
                        "code": -32601,
                        "message": f"unsupported client method: {method}",
                    },
                },
            )
    raise RuntimeError(f"Moltis ACP process closed before response {request_id}")


def main() -> int:
    args = parse_args()
    process = subprocess.Popen(
        [
            args.moltis_binary,
            "acp",
            "--config-dir",
            args.config_dir,
            "--data-dir",
            args.data_dir,
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None
    assert process.stdout is not None

    try:
        send(
            process.stdin,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": 1,
                    "clientCapabilities": {},
                    "clientInfo": {
                        "name": "ai-node-cli-benchmark",
                        "version": "1",
                    },
                },
            },
        )
        read_response(process.stdout, process.stdin, 1)

        send(
            process.stdin,
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "session/new",
                "params": {
                    "cwd": str(args.cwd.resolve()),
                    "mcpServers": [],
                },
            },
        )
        session = read_response(process.stdout, process.stdin, 2)
        session_id = session.get("sessionId")
        if not isinstance(session_id, str):
            raise RuntimeError("Moltis ACP session/new omitted sessionId")

        send(
            process.stdin,
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "session/prompt",
                "params": {
                    "sessionId": session_id,
                    "prompt": [{"type": "text", "text": args.prompt}],
                },
            },
        )
        read_response(process.stdout, process.stdin, 3)
        print()
        return 0
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=10)


if __name__ == "__main__":
    raise SystemExit(main())

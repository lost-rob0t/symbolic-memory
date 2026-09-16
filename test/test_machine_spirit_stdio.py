#!/usr/bin/env python3
"""Exercise the real MCP process across restarts; no provider or network needed."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SWIPL = shutil.which("swipl")
TIMEOUT_SECONDS = 15


class MachineSpiritStdioTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="machine-spirit-")
        self.addCleanup(self.directory.cleanup)
        self.environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith("SYMBOLIC_MEMORY_")
        }
        self.environment.update({
            "SYMBOLIC_MEMORY_DB": str(Path(self.directory.name) / "memory.db"),
            "SYMBOLIC_MEMORY_PRINCIPAL": "stdio-test",
            "SYMBOLIC_MEMORY_SESSION_ID": "stdio-session",
            "SYMBOLIC_MEMORY_SOURCE_CLASS": "user_explicit",
            "SYMBOLIC_MEMORY_CAPABILITIES": "memory_read,memory_write_session",
        })

    def session(self, calls: list[tuple[str, dict[str, Any]]]) -> list[dict[str, Any]]:
        self.assertIsNotNone(SWIPL, "SWI-Prolog is required; missing runtime is not a skip")
        requests: list[dict[str, Any]] = [{
            "jsonrpc": "2.0", "id": 0, "method": "initialize",
            "params": {"protocolVersion": "2025-11-25", "capabilities": {},
                       "clientInfo": {"name": "machine-spirit-test", "version": "1"}},
        }, {"jsonrpc": "2.0", "method": "notifications/initialized"}]
        requests.extend({
            "jsonrpc": "2.0", "id": index, "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        } for index, (name, arguments) in enumerate(calls, start=1))
        payload = "".join(json.dumps(request, ensure_ascii=False) + "\n"
                          for request in requests)
        process = subprocess.run(
            [str(SWIPL), "-q", "-s", str(ROOT / "prolog/symbolic_memory_mcp.pl")],
            input=payload, capture_output=True, encoding="utf-8", check=False,
            timeout=TIMEOUT_SECONDS, env=self.environment, cwd=ROOT,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertNotIn("ERROR:", process.stderr)
        responses = [json.loads(line) for line in process.stdout.splitlines() if line.strip()]
        self.assertEqual(len(responses), len(calls) + 1, process.stdout)
        self.assertEqual([response["id"] for response in responses],
                         list(range(len(calls) + 1)))
        results = []
        for response in responses[1:]:
            self.assertNotIn("error", response, response)
            result = response["result"]
            self.assertFalse(result["isError"], result)
            structured = result["structuredContent"]
            self.assertEqual(structured["model_calls"], 0)
            results.append(structured)
        return results

    def test_source_projection_retry_withdrawal_and_restart(self) -> None:
        source = "Use Prolog for verification.\nExact source: λ, café.\n"
        stored, = self.session([("memory_remember", {"memory": source})])
        memory_id = stored["id"]
        self.assertEqual(stored["projection_status"], "not_attempted")
        projection = {
            "id": memory_id, "request_id": "first", "expected_generation": 0,
            "projections": [{"predicate": "verifier", "arguments": ["user", "prolog"],
                             "statement": "Use Prolog for verification.", "quality": "exact"}],
        }
        ready, recalled, status = self.session([
            ("memory_project", projection),
            ("memory_recall", {"predicate": "verifier", "arguments": ["user", None]}),
            ("memory_projection_status", {"id": memory_id}),
        ])
        self.assertEqual(ready["status"], "ready")
        self.assertEqual(ready["generation"], 1)
        self.assertEqual(len(recalled["memories"]), 1)
        self.assertEqual(status["current_generation"], 1)
        retry, withdrawn, empty = self.session([
            ("memory_project", projection),
            ("memory_projection_withdraw", {"id": memory_id, "reason": "Source corrected",
                                            "expected_generation": 1}),
            ("memory_recall", {"predicate": "verifier"}),
        ])
        self.assertEqual(retry["status"], "already_present")
        self.assertEqual(retry["event_id"], ready["event_id"])
        self.assertEqual(withdrawn["generation"], 2)
        self.assertEqual(empty["memories"], [])
        historical, original, history, empty = self.session([
            ("memory_project", projection),
            ("memory_get", {"id": memory_id}),
            ("memory_projection_history", {"id": memory_id}),
            ("memory_recall", {"predicate": "verifier"}),
        ])
        self.assertFalse(historical["is_current"])
        self.assertEqual(historical["current_status"], "withdrawn")
        self.assertEqual(original["source_text"], source)
        self.assertEqual(original["projections"], [])
        self.assertEqual([event["state"] for event in history["events"]], ["ready", "withdrawn"])
        self.assertEqual(empty["memories"], [])


if __name__ == "__main__":
    if SWIPL is None:
        print("ERROR: swipl is required to run the MCP stdio regression.", file=sys.stderr)
        sys.exit(2)
    unittest.main()

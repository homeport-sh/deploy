#!/usr/bin/env python3
"""A stand-in for GitHub's OIDC endpoint and the homeport API.

It is deliberately not a mock of the action's own code — it is the other side
of the protocol, so the test finds out whether deploy.sh actually speaks it.
Behaviour is steered by a scenario name in the environment, which is how the
failure paths get exercised without needing a broken control plane.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SCENARIO = os.environ.get("SCENARIO", "happy")
STATE = {"uploaded": b"", "polls": 0}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        return self.headers.get("Authorization", "")

    def do_GET(self):
        # GitHub's OIDC token endpoint.
        if self.path.startswith("/token"):
            if "audience=" not in self.path:
                return self._json(400, {"error": "no audience"})
            if self._auth() != "Bearer request-token":
                return self._json(401, {"error": "bad request token"})
            return self._json(200, {"value": "oidc.jwt.forged"})

        # Deployment status.
        if self.path.startswith("/v1/deployments/"):
            if self._auth() != "Bearer completion-token":
                return self._json(403, {"error": "not authorized for this deployment"})
            STATE["polls"] += 1
            if SCENARIO == "deploy-fails":
                return self._json(200, {
                    "deployment_id": "d-1", "status": "failed",
                    "detail": "health check failed: 502 from 127.0.0.1:8080",
                })
            if SCENARIO == "slow" and STATE["polls"] < 3:
                return self._json(200, {"deployment_id": "d-1", "status": "deploying"})
            return self._json(200, {"deployment_id": "d-1", "status": "live"})

        return self._json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""

        if self.path == "/v1/deployments":
            if self._auth() != "Bearer oidc.jwt.forged":
                return self._json(401, {"error": "token rejected"})
            if SCENARIO == "not-authorized":
                return self._json(403, {"error": "not authorized for this app"})
            if SCENARIO == "box-not-ready":
                return self._json(409, {"error": "box is not ready"})
            try:
                sent = json.loads(body)
            except ValueError:
                return self._json(400, {"error": "malformed request body"})
            if sent.get("app") != "website":
                return self._json(403, {"error": "not authorized for this app"})
            return self._json(201, {
                "deployment_id": "d-1",
                "upload_url": f"http://{self.headers['Host']}/upload/d-1",
                "expires_at": "2026-08-14T12:05:00Z",
                "completion_token": "completion-token",
            })

        if self.path.endswith("/complete"):
            if self._auth() != "Bearer completion-token":
                return self._json(403, {"error": "not authorized for this deployment"})
            if SCENARIO == "bad-artifact":
                return self._json(422, {"error": "artifact does not match the box architecture"})
            if not STATE["uploaded"]:
                return self._json(400, {"error": "no artifact was uploaded"})
            return self._json(200, {
                "deployment_id": "d-1", "status": "uploaded",
                "arch": "x86-64", "bytes": len(STATE["uploaded"]),
            })

        return self._json(404, {"error": "not found"})

    def do_PUT(self):
        if not self.path.startswith("/upload/"):
            return self._json(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length") or 0)
        STATE["uploaded"] = self.rfile.read(length)
        self.send_response(200)
        self.end_headers()


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    sys.stdout.flush()
    server.serve_forever()

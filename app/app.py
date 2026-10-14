"""ShipFast API - a minimal Flask status check service."""
import logging
import os

from flask import Flask, jsonify
from werkzeug.exceptions import HTTPException

APP_NAME = os.getenv("APP_NAME", "shipfast-status")
APP_ENV = os.getenv("APP_ENV", "development")

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)


@app.get("/status")
def status():
    """Describe the running application."""
    return jsonify(application=APP_NAME, status="running", environment=APP_ENV)


@app.get("/health")
def health():
    """Lightweight check for Kubernetes probes: 200 means the process can serve requests."""
    return jsonify(status="healthy")


@app.errorhandler(HTTPException)
def handle_http_error(err):
    """Return 404, 405, etc. as JSON instead of Flask's default HTML pages."""
    return jsonify(error=err.name, message=err.description), err.code


@app.errorhandler(Exception)
def handle_unexpected_error(err):
    """Log unexpected failures and return a generic 500 without leaking internals."""
    app.logger.exception("Unhandled error: %s", err)
    return jsonify(error="Internal Server Error", message="An unexpected error occurred."), 500


if __name__ == "__main__":
    # Local development only; the container runs gunicorn instead.
    app.run(host="127.0.0.1", port=int(os.getenv("PORT", "8080")))

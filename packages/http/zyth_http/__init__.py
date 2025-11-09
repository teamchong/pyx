"""
zyth.http - HTTP client/server module

HTTP utilities for Zyth.
Actual implementation in src/http.zig
"""

__version__ = "0.1.0"


class HttpClient:
    """HTTP client"""

    def get(self, url: str) -> dict:
        """HTTP GET request"""
        ...

    def post(self, url: str, data: dict) -> dict:
        """HTTP POST request"""
        ...

"""
zyth.web - Web framework module

FastAPI-like web framework for Zyth.
Actual implementation in src/web.zig
"""

__version__ = "0.1.0"

# Type stubs for IDE support
class Request:
    """HTTP Request"""
    method: str
    path: str
    headers: dict[str, str]
    body: str


class Response:
    """HTTP Response"""
    status: int
    headers: dict[str, str]
    body: str

    @staticmethod
    def json(data: dict) -> "Response":
        """Create JSON response"""
        ...


class App:
    """Web application"""

    def __init__(self) -> None:
        """Create new app"""
        ...

    def get(self, path: str):
        """Register GET route"""
        def decorator(handler):
            return handler
        return decorator

    def post(self, path: str):
        """Register POST route"""
        def decorator(handler):
            return handler
        return decorator

    def run(self, port: int = 8000) -> None:
        """Run the web server"""
        ...

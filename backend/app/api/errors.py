"""Every 4xx/5xx answer of the API has the shape of contracts/rest/error_response.json."""

from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.contracts.rest.error_response import ErrorResponse

_CODES = {
    400: "bad_request",
    401: "unauthorized",
    403: "forbidden",
    404: "not_found",
    405: "method_not_allowed",
    409: "conflict",
    422: "validation_error",
    429: "too_many_attempts",
}

# For route declarations: these statuses answer with ErrorResponse.
ERRORS = {status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 422, 429)}


class ApiException(Exception):
    """An error a client acts on by `code`; `message` is for logs and developers, not for users."""

    def __init__(
        self, status_code: int, code: str, message: str, seller_contacts: dict[str, Any] | None = None
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        # License errors: how the club reaches its seller (SPEC 8.4).
        self.seller_contacts = seller_contacts


def _body(code: str, message: str, seller_contacts: dict[str, Any] | None = None) -> dict[str, object]:
    detail: dict[str, Any] = {"code": code, "message": message}
    if seller_contacts:
        detail["seller_contacts"] = seller_contacts
    return ErrorResponse.model_validate({"detail": detail}).model_dump(mode="json", exclude_none=True)


def install(app: FastAPI) -> None:
    @app.exception_handler(ApiException)
    async def api_exception(_: Request, exc: ApiException) -> JSONResponse:
        return JSONResponse(_body(exc.code, exc.message, exc.seller_contacts), status_code=exc.status_code)

    @app.exception_handler(StarletteHTTPException)
    async def http_exception(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        code = _CODES.get(exc.status_code, "error")
        return JSONResponse(_body(code, str(exc.detail)), status_code=exc.status_code, headers=exc.headers)

    @app.exception_handler(RequestValidationError)
    async def validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        first = exc.errors()[0] if exc.errors() else {}
        where = ".".join(str(part) for part in first.get("loc", ()))
        return JSONResponse(_body("validation_error", f"{where}: {first.get('msg', 'invalid')}"), status_code=422)

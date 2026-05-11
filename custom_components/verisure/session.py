"""Verisure Session with persisted cookie hydrate before refresh."""

from __future__ import annotations

import pickle

from verisure import LoginError
from verisure.session import Session as VerisureSessionBase


class VerisureHydratedSession(VerisureSessionBase):
    """Load cookies from disk when in-memory jars are unset (avoids empty /auth/token)."""

    def update_cookie(self) -> None:
        """Refresh auth token cookie, loading from file if `_cookies` is unset."""
        if self._cookies is None:
            self._load_persisted_cookies()
        super().update_cookie()

    def _load_persisted_cookies(self) -> None:
        try:
            with open(self._cookie_file_name, "rb") as cookie_file:
                self._cookies = pickle.load(cookie_file)
        except Exception as ex:
            raise LoginError("Failed to read cookie") from ex

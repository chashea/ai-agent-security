"""Pytest bootstrap.

Adds the repository root to ``sys.path`` so test modules under
``scripts/tests/`` can use ``from scripts import <module>`` imports without
requiring ``scripts/`` to be installed as a package. Older test files use a
manual ``sys.path.insert`` inside the module instead — both styles continue
to work with this conftest in place.
"""

from __future__ import annotations

import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

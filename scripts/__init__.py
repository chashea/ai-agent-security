"""Marker file so ``from scripts import ...`` works in tests.

The repo treats ``scripts/`` as a flat collection of standalone CLIs that are
also imported by tests. Most legacy tests use ``sys.path.insert`` to import
modules directly (e.g. ``from foundry_agents import ...``); newer tests use
``from scripts import attack_agents``. Both styles work as long as this
package marker exists *and* the repo root is on ``sys.path`` (handled by the
top-level ``conftest.py``).
"""

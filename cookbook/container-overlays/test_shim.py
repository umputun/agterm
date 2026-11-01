#!/usr/bin/env python3
"""Runs the wrapper's and the receiver's embedded selftest suites; the
cookbook CI executes this file."""

import importlib.util
import os
import sys
import unittest
from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))

# (module name, file) — the receiver's hyphenated filename cannot be
# imported by name, so both load through an explicit SourceFileLoader.
MODULES = (
    ("agtermctl", "agtermctl.py"),
    ("agtermctl_receiver", "agtermctl-receiver.py"),
)


def load_module(modname, filename):
    loader = SourceFileLoader(modname, os.path.join(HERE, filename))
    spec = importlib.util.spec_from_loader(modname, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def main():
    suite = unittest.TestSuite()
    for modname, filename in MODULES:
        suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(
            load_module(modname, filename)))
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()

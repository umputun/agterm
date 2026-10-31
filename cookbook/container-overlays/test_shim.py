#!/usr/bin/env python3
"""Runs the wrapper's embedded selftest suite; the cookbook CI executes this file."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agtermctl


def main():
    suite = unittest.defaultTestLoader.loadTestsFromModule(agtermctl)
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()

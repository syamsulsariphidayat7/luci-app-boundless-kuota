#!/usr/bin/env python3
"""Jalankan uji Lua inti boundless-kuota lewat lupa."""
import os
import sys

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().arg = lua.table_from([ROOT])
lua.execute(open(os.path.join(HERE, "core_test.lua"), encoding="utf-8").read())
fail = lua.globals().TEST_FAIL
sys.exit(0 if fail == 0 else 1)

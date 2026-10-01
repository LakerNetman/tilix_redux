#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
# distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
"""
Checks the command the Nautilus extension builds for "Open Remote Tilix".

The command goes through two rounds of parsing: Tilix splits the -e value into
arguments with g_shell_parse_argv, then ssh joins the arguments after the host
with spaces and hands them to the remote shell. This simulates both and runs
the result with a local shell to check the directory is reached exactly and
nothing in the path is executed.

Exits with 77 (skipped) if PyGObject is not available.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import types
from urllib.parse import quote

try:
    import gi
    from gi.repository import GLib
except ImportError:
    print("PyGObject is not available, skipping")
    sys.exit(77)

EXTENSION = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "nautilus", "open-tilix.py")


def load_extension():
    # Nautilus is not needed to build the command, provide a stand in so the
    # extension can be imported without it. Without LocationWidgetProvider the
    # extension doesn't load Gtk either.
    nautilus = types.ModuleType("gi.repository.Nautilus")
    nautilus.MenuProvider = type("MenuProvider", (object,), {})
    nautilus.MenuItem = object
    sys.modules["gi.repository.Nautilus"] = nautilus
    spec = importlib.util.spec_from_file_location("open_tilix", EXTENSION)
    module = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(module)
    return module


def remote_arguments(command):
    """Returns the arguments Tilix passes to ssh and the command ssh sends to the remote shell"""
    ok, argv = GLib.shell_parse_argv(command)
    assert ok, command
    assert argv[:2] == ["ssh", "-t"], argv
    index = 3
    if len(argv) > 4 and argv[3] == "-p":
        index = 5
    return argv[:index], " ".join(argv[index:])


def main():
    extension = load_extension()
    failures = 0
    root = tempfile.mkdtemp(prefix="tilix-nautilus-test-")
    marker = os.path.join(root, "PWNED")
    names = [
        "plain",
        "my dir",
        "x;touch " + marker,
        "$(touch " + marker + ")",
        "`touch " + marker + "`",
        "it's",
        "quote\"s",
        "a%20b",
        "back\\slash",
        "ü nicode",
    ]
    for name in names:
        path = os.path.join(root, name)
        os.makedirs(path, exist_ok=True)
        uri = "sftp://user@example.com:2222" + quote(path)
        command = extension.remote_terminal_command(uri, True)
        ssh_args, remote = remote_arguments(command)
        # Run what the remote shell would run, with $SHELL printing the directory
        result = subprocess.run(["/bin/sh", "-c", remote], env=dict(os.environ, SHELL="pwd"),
                                capture_output=True, text=True)
        problems = []
        if ssh_args != ["ssh", "-t", "user@example.com", "-p", "2222"]:
            problems.append("unexpected ssh arguments %r" % ssh_args)
        if result.stdout != path + "\n":
            problems.append("reached %r, stderr %r" % (result.stdout, result.stderr.strip()))
        if os.path.exists(marker):
            problems.append("the path was executed")
            os.remove(marker)
        if problems:
            failures += 1
            print("FAIL %r: %s\n     command: %s" % (name, "; ".join(problems), command))
        else:
            print("ok   %r" % name)

    # Without a user or port, and for a file rather than a directory
    ssh_args, remote = remote_arguments(extension.remote_terminal_command("sftp://example.com/tmp", True))
    if ssh_args != ["ssh", "-t", "example.com"]:
        failures += 1
        print("FAIL no user or port: %r" % ssh_args)
    if extension.remote_terminal_command("sftp://user@example.com/tmp/file.txt", False) != "ssh -t user@example.com":
        failures += 1
        print("FAIL file: %r" % extension.remote_terminal_command("sftp://user@example.com/tmp/file.txt", False))

    subprocess.run(["rm", "-rf", root])
    print("%d failures" % failures)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

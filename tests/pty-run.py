#!/usr/bin/env python3
"""Run a command with a controlled terminal for interactive CLI tests.

Default (TTY) mode:
  * stdin, and therefore the controlling terminal, is a pseudo-terminal;
  * stdout and stderr are redirected to regular files;
  * /dev/tty resolves to the pseudo-terminal;
  * bytes from --input are written to the terminal once the child starts
    producing prompt output (or after a short grace period).

--no-tty mode:
  * the command starts in a new session with no controlling terminal;
  * stdin is /dev/null;
  * stdout and stderr are redirected to regular files.

The process exit status is returned. This helper is used only by
tests/interactive.sh.

SPDX-FileCopyrightText: 2026 Plak Solutions S.A.C. <info@plak.io>
SPDX-License-Identifier: AGPL-3.0-or-later
"""

import argparse
import errno
import fcntl
import os
import pty
import select
import struct
import subprocess
import sys
import termios
import time

TIMEOUT_SECONDS = 30


def read_input(path):
    if not path:
        return b""
    if path == "-":
        data = sys.stdin.buffer.read()
    else:
        with open(path, "rb") as handle:
            data = handle.read()
    # Real gum puts the terminal in raw mode, where Enter is CR rather than
    # NL. Sending CR also works in canonical mode (the line discipline maps it
    # back to NL), so normalize line endings for both real and fake gum.
    return data.replace(b"\r\n", b"\r").replace(b"\n", b"\r")


def exit_code(status):
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


def run_tty(command, stdout_path, stderr_path, input_path, tty_out_path):
    data = read_input(input_path)
    pid, master = pty.fork()
    if pid == 0:
        try:
            out_fd = os.open(
                stdout_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600
            )
            err_fd = os.open(
                stderr_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600
            )
            os.dup2(out_fd, 1)
            os.dup2(err_fd, 2)
            os.close(out_fd)
            os.close(err_fd)
            os.execvp(command[0], command)
        except BaseException:
            os._exit(127)

    # Give gum a realistic window size; it uses the TTY width for its TUI.
    fcntl.ioctl(
        master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0)
    )

    tty_chunks = []
    input_sent = False
    status = None
    eof = False
    started = time.time()

    def send_input():
        nonlocal input_sent
        if data:
            try:
                os.write(master, data)
            except OSError:
                pass
        input_sent = True

    while time.time() - started < TIMEOUT_SECONDS:
        if not eof:
            try:
                readable, _, _ = select.select([master], [], [], 0.1)
            except InterruptedError:
                readable = []

            if readable:
                try:
                    chunk = os.read(master, 65536)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        chunk = b""
                    else:
                        raise
                if chunk:
                    tty_chunks.append(chunk)
                    # Wait for the prompt to render before typing, so programs
                    # that flush pending input on startup do not lose it.
                    if not input_sent:
                        time.sleep(0.05)
                        send_input()
                else:
                    eof = True
            elif not input_sent and time.time() - started > 0.5:
                send_input()

        done, wait_status = os.waitpid(pid, os.WNOHANG)
        if done:
            status = wait_status
            # Drain anything still buffered on the master.
            while True:
                try:
                    ready, _, _ = select.select([master], [], [], 0)
                except InterruptedError:
                    continue
                if not ready:
                    break
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                tty_chunks.append(chunk)
            break
        time.sleep(0.01)

    if status is None:
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
        _, status = os.waitpid(pid, 0)
        print("pty-run: timed out waiting for the command", file=sys.stderr)
        rc = 124
    else:
        rc = exit_code(status)

    os.close(master)
    if tty_out_path:
        with open(tty_out_path, "wb") as handle:
            handle.write(b"".join(tty_chunks))
    return rc


def run_without_tty(command, stdout_path, stderr_path):
    with open(stdout_path, "wb") as out, open(stderr_path, "wb") as err:
        proc = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=out,
            stderr=err,
            start_new_session=True,
        )
    return proc.returncode


def main():
    parser = argparse.ArgumentParser(
        description="Run a command with or without a controlling terminal."
    )
    parser.add_argument("--stdout", required=True, help="file for the command STDOUT")
    parser.add_argument("--stderr", required=True, help="file for the command STDERR")
    parser.add_argument("--input", help="file with bytes to type on the TTY")
    parser.add_argument("--tty-out", help="file with raw TTY output (prompt UI)")
    parser.add_argument(
        "--no-tty",
        action="store_true",
        help="start a new session with no controlling terminal",
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("missing command (use: -- <command> [args...])")

    if args.no_tty:
        rc = run_without_tty(command, args.stdout, args.stderr)
    else:
        rc = run_tty(
            command, args.stdout, args.stderr, args.input, args.tty_out
        )
    return rc


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# Copyright 2014 The Chromium Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""Helper script for GN to run `dart compile exe` and produce a depfile.

Run with:
  python3 gn_dart_compile_exe.py             \
    --dart-binary <path to dart binary>      \
    --entry-point <path to dart entry point>       \
    --output <path to resulting executable>  \
    --sdk-hash <SDK hash>                    \
    --packages <path to package config file> \
    --depfile <path to depfile to write>

This is workaround for `dart compile exe` not supporting --depfile option
in the current version of prebuilt SDK. Once we roll in a new version
of checked in SDK we can remove this helper.
"""

import argparse
import os
import sys
import subprocess
from tempfile import TemporaryDirectory


def parse_args(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--dart-sdk",
                        required=True,
                        help="Path to the prebuilt Dart SDK")
    parser.add_argument("--sdk-hash", required=True, help="SDK hash")
    parser.add_argument("--entry-point",
                        required=True,
                        help="Dart entry point to precompile")
    parser.add_argument("--output",
                        required=True,
                        help="Path to resulting executable   ")
    parser.add_argument("--packages",
                        required=True,
                        help="Path to package config file")
    parser.add_argument("--depfile",
                        required=True,
                        help="Path to depfile to write")
    return parser.parse_args(argv)


# Run a command, swallowing the output unless there is an error.
def run_command(command):
    try:
        subprocess.check_output(command, stderr=subprocess.STDOUT)
        return True
    except subprocess.CalledProcessError as e:
        print("Command failed: " + " ".join(command) + "\n" + "output: " +
              _decode(e.output))
        return False
    except OSError as e:
        print("Command failed: " + " ".join(command) + "\n" + "output: " +
              _decode(e.strerror))
        return False


def _decode(bytes):
    return bytes.decode("utf-8")


def main(argv):
    args = parse_args(argv[1:])

    # Unless the path is absolute, this script is designed to run binaries
    # produced by the current build, which is the current working directory when
    # this script is run.
    prebuilt_sdk = os.path.abspath(args.dart_sdk)

    dart_binary = os.path.join(prebuilt_sdk, "bin", "dart")
    if not os.path.isfile(dart_binary):
        print("Binary not found: " + dart_binary)
        return 1

    # Compile the executable.
    ok = run_command([
        dart_binary,
        "compile",
        "exe",
        "--packages",
        args.packages,
        f"-Dsdk_hash={args.sdk_hash}",
        "--depfile",
        args.depfile,
        "-o",
        args.output,
        args.entry_point,
    ])
    if not ok:
        return 1

    # Fix generated depfile to refer to the relative output file name
    # instead referring to it using absolute path. ninja does not support
    # that.
    with open(args.depfile, "r") as f:
        content = f.read()
    deps = content.split(": ", 1)[1]
    with open(args.depfile, "w") as f:
        f.write(args.output)
        f.write(": ")
        f.write(deps)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

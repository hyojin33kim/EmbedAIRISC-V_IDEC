"""Legacy command launcher only. All image processing/inference/output is in C main().

Preferred command: ./build/inference --image IMAGE
This file imports no PyTorch, NumPy, Pillow or ctypes and can be omitted on the device.
"""

import os
import sys
from pathlib import Path


def main(argv=None):
    executable = Path(__file__).resolve().parent / 'build/inference'
    if not executable.is_file():
        raise SystemExit('Build the C executable first: cd int8_c && make')
    arguments = sys.argv[1:] if argv is None else argv
    os.execv(str(executable), [str(executable), *arguments])


if __name__ == '__main__':
    main()

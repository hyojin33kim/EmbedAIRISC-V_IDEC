# 독립 VCS 프로세스로 전체 CNN 입력을 분할 실행하고 모든 계층 통과를 확인한다.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
import argparse
import concurrent.futures
import re
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sim", type=Path, required=True)
    parser.add_argument("--golden", type=Path, required=True)
    parser.add_argument("--logs", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 372:
        parser.error("--jobs must be 1..372")
    args.logs.mkdir(exist_ok=True, parents=True)

    def run(index):
        first = index * 372 // args.jobs
        last = (index + 1) * 372 // args.jobs
        log = args.logs.resolve() / f"cnn_{index:02d}.log"
        command = [str(args.sim.resolve()), "-no_save", "+vcs+lic+wait", f"+GOLDEN={args.golden.resolve()}",
                   f"+CASE_START={first*6}", f"+CASE_COUNT={(last-first)*6}"]
        def complete(content):
            ids = [int(value) for value in re.findall(r"\[PASS\] top case=(\d+)",content)]
            return (ids == list(range(first*6,last*6)) and "[PASS] tb_tinynpu_top" in content
                    and not re.search(r"(?:^|\n)\s*(?:Fatal:|Error:|\[FAIL\])",content))
        with log.open("w") as stream:
            result = subprocess.run(command, cwd=args.logs, stdout=stream, stderr=subprocess.STDOUT)
        content = log.read_text()
        if result.returncode or not complete(content):
            raise RuntimeError(f"CNN shard {index} failed; see {log}")
        print(f"[PASS] CNN shard {index}: samples {first}..{last-1}, {(last-first)*6} layer comparisons",flush=True)
        return (last-first)*6

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        count = sum(pool.map(run, range(args.jobs)))
    if count != 2232:
        raise RuntimeError(f"incomplete CNN coverage: {count}")
    print("[PASS] CNN 372 inputs, 2232 layers, 1393884 trace bytes and all output guards")


if __name__ == "__main__":
    main()

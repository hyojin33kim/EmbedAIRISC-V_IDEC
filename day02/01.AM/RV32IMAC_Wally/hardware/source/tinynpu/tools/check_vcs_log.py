# VCS의 종료 코드와 별개로 오류 및 검증 완료 표식을 검사한다.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
import argparse
import collections
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("--lint", action="store_true")
    parser.add_argument("--compile", action="store_true")
    args = parser.parse_args()
    content = args.log.read_text(errors="replace")
    if re.search(r"(?:^|\n)\s*(?:Fatal:|Error:|Error-|Warning-|\[FAIL\])", content):
        raise SystemExit(f"[FAIL] VCS diagnostic in {args.log}")
    if args.lint:
        waived = collections.Counter()
        for item in re.split(r"(?=^Lint-\[)", content, flags=re.M)[1:]:
            item = item.split("\n\n", 1)[0]
            tag = re.match(r"Lint-\[([^]]+)\]", item).group(1)
            permitted = (
                (tag == "SVA-CE" and '"(!rst_n)"' in item)
                or (tag == "SVA-DIU" and "!rst_n" in item)
                or (tag == "UI" and "tinynpu_top.sv" in item and
                    re.search(r"Source info: s_H(?:BURST|PROT|MASTLOCK)\b", item))
            )
            if not permitted:
                raise SystemExit(f"[FAIL] unwaived RTL lint in {args.log}\n{item}")
            waived[tag] += 1
        print(f"[PASS] RTL lint: zero unwaived diagnostics; documented style/interface waivers {dict(waived)}")
    elif not args.compile and not re.search(r"^\[PASS\] tb_tinynpu_[a-z_]+\b",content,re.M):
        raise SystemExit(f"[FAIL] missing completion marker in {args.log}")
    elif not args.compile:
        print(f"[PASS] checked simulator log {args.log.name}")


if __name__ == "__main__":
    main()

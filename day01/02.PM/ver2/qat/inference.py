"""QAT INT8 추론. PTQ와 동일한 로더/전처리를 사용."""

import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE.parent / "ptq"))
from quant_inference import main  # noqa: E402


if __name__ == "__main__":
    main(default_model=BASE / "outputs/model_int8.pt")

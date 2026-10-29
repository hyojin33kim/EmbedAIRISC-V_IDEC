"""QAT의 실제 INT8 weight/scale을 portable C11 header와 정렬된 binary로 추출."""

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path

import numpy as np
import torch

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE.parent / "ptq"))
from quant_common import IMAGE_SIZE, load_int8, setup_runtime  # noqa: E402


def quantized_multiplier(value):
    """value ≈ multiplier / 2**right_shift, 정규화된 Q31 mantissa."""
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"Invalid requantization factor: {value}")
    fraction, exponent = math.frexp(value)
    multiplier = round(fraction * (1 << 31))  # ties-to-even
    if multiplier == 1 << 31:
        multiplier //= 2
        exponent += 1
    shift = 31 - exponent
    if not 1 <= shift <= 62:
        raise ValueError(f"Requantization shift outside portable int64 range: {shift}")
    return multiplier, shift


def checked_scale(value):
    value = float(np.float32(value))
    if not math.isfinite(value) or value <= 0:
        raise ValueError("Quantization scale must be finite and positive.")
    return value


def float_literal(value):
    value = float(np.float32(value))
    if not math.isfinite(value):
        raise ValueError("Cannot export NaN/Inf to C")
    literal = format(value, ".9g")  # float32 round trip
    if "." not in literal and "e" not in literal.lower():
        literal += ".0"
    return literal + "f"


def extract_model(checkpoint_path):
    model, artifact = load_int8(checkpoint_path)
    config = artifact["model_config"]
    if config.get("bias", False):
        raise ValueError("This teaching runtime supports bias=False CNN checkpoints only.")
    preprocessing = artifact["preprocessing"]
    if (preprocessing.get("image_size") != IMAGE_SIZE or preprocessing.get("channels") != 1
            or preprocessing.get("alpha_background") != "white"
            or preprocessing.get("resize") != "bilinear"
            or preprocessing.get("input_mode") not in {"foreground", "signed"}):
        raise ValueError("Unsupported input preprocessing")
    classes = artifact["classes"]
    if artifact["class_to_idx"] != {name: i for i, name in enumerate(classes)}:
        raise ValueError("Class mapping is inconsistent")
    input_scale = checked_scale(model.quant.scale.item())
    input_zero = int(model.quant.zero_point.item())
    if model.quant.dtype != torch.quint8 or not 0 <= input_zero <= 255:
        raise ValueError("Expected quint8 model input")
    scale, zero, c, h, w = input_scale, input_zero, 1, IMAGE_SIZE, IMAGE_SIZE
    layers = []
    names = [f"features.{3 * i}" for i in range(config["conv_blocks"])]
    names += ["classifier.1", "classifier.3"]
    trace_offset = 0
    for index, name in enumerate(names):
        module = model.get_submodule(name)
        weight = module.weight()
        if weight.dtype != torch.qint8 or module.bias() is not None:
            raise ValueError(f"Expected bias-free qint8 weight at {name}")
        shape = list(weight.shape)
        is_conv = name.startswith("features")
        relu = name != "classifier.3"
        if is_conv:
            if (tuple(module.kernel_size) != (3, 3) or tuple(module.stride) != (1, 1)
                    or tuple(module.padding) != (1, 1) or tuple(module.dilation) != (1, 1)
                    or module.groups != 1 or shape[1] != c or h % 2 or w % 2):
                raise ValueError(f"Unsupported Conv geometry at {name}")
            pool = model.get_submodule(f"features.{3 * index + 2}")
            if (pool.kernel_size != 2 or pool.stride != 2 or pool.padding != 0
                    or pool.dilation != 1 or pool.ceil_mode):
                raise ValueError("Expected 2x2 stride-2 MaxPool")
            out_c, out_h, out_w = shape[0], h // 2, w // 2
        else:
            if shape[1] != c * h * w:
                raise ValueError(f"Unexpected Linear input shape at {name}")
            out_c, out_h, out_w = shape[0], 1, 1
        if weight.qscheme() in (torch.per_channel_affine, torch.per_channel_symmetric):
            if weight.q_per_channel_axis() != 0:
                raise ValueError("Only output-channel weight quantization (axis=0) supported")
            scales = weight.q_per_channel_scales().numpy()
            zeros = weight.q_per_channel_zero_points().numpy()
        elif weight.qscheme() in (torch.per_tensor_affine, torch.per_tensor_symmetric):
            scales = np.repeat(weight.q_scale(), out_c)
            zeros = np.repeat(weight.q_zero_point(), out_c)
        else:
            raise ValueError(f"Unsupported qscheme: {weight.qscheme()}")
        # Current QAT scales are float32 values stored in torch's float64 scale container.
        if not np.array_equal(scales, scales.astype(np.float32).astype(np.float64)):
            raise ValueError("Weight scale loses precision in float32; unsupported source")
        scales = scales.astype(np.float32)
        if not np.isfinite(scales).all() or (scales <= 0).any() or (zeros < -128).any() or (zeros > 127).any():
            raise ValueError("Invalid weight quantization parameters")
        q = weight.int_repr().contiguous().numpy().astype(np.int8)
        output_scale, output_zero = checked_scale(module.scale), int(module.zero_point)
        if not 0 <= output_zero <= 255:
            raise ValueError("Expected quint8 layer output")
        # Float32 parameter values are combined in double at export; no FP math in the C core.
        factors = [scale * float(s) / output_scale for s in scales]
        pairs = [quantized_multiplier(factor) for factor in factors]
        centered = q.astype(np.int64).reshape(out_c, -1) - zeros[:, None]
        bounds = np.abs(centered).sum(1) * max(abs(zero), abs(255 - zero))
        if np.max(bounds) > np.iinfo(np.int32).max:
            raise ValueError(f"INT32 accumulator bound exceeded at {name}")
        layer = {
            "name": name, "symbol": f"conv{index + 1}" if is_conv else f"fc{index - config['conv_blocks'] + 1}",
            "type": "conv_pool" if is_conv else "linear", "relu": relu,
            "input_shape": [c, h, w], "output_shape": [out_c, out_h, out_w],
            "weight_shape": shape, "weight_layout": "OIHW" if is_conv else "OI",
            "weight_dtype": "int8", "activation_dtype": "uint8",
            "weight_qscheme": str(weight.qscheme()), "weight_axis": 0,
            "input_scale": scale, "input_zero_point": zero,
            "output_scale": output_scale, "output_zero_point": output_zero,
            "weight_scales": scales.tolist(), "weight_zero_points": zeros.astype(int).tolist(),
            "multipliers": [p[0] for p in pairs], "right_shifts": [p[1] for p in pairs],
            "requantization_factors": factors, "accumulator_abs_bound": int(bounds.max()),
            "trace_offset": trace_offset, "output_elements": out_c * out_h * out_w,
            "weight": q,
        }
        layers.append(layer)
        trace_offset += layer["output_elements"]
        scale, zero, c, h, w = output_scale, output_zero, out_c, out_h, out_w
    if c != len(classes):
        raise ValueError("Output/classes mismatch")
    return model, artifact, layers, input_scale, input_zero


def c_array(name, ctype, values, floating=False):
    flat = np.asarray(values).reshape(-1)
    result = [f"extern const {ctype} {name}[{len(flat)}];", "#ifdef MODEL_DATA_IMPLEMENTATION",
              f"_Alignas(MODEL_ALIGNMENT) const {ctype} {name}[{len(flat)}] = {{"]
    for offset in range(0, len(flat), 16):
        items = [float_literal(x) if floating else str(int(x)) for x in flat[offset:offset + 16]]
        result.append("    " + ", ".join(items) + ",")
    result += ["};", "#endif", ""]
    return "\n".join(result)


def export_model(checkpoint_path, output_dir, alignment=16):
    if alignment < 1 or alignment > 256 or alignment & (alignment - 1):
        raise ValueError("alignment must be a power of two from 1 to 256")
    checkpoint_path, output_dir = Path(checkpoint_path).resolve(), Path(output_dir).resolve()
    if output_dir == checkpoint_path.parent:
        raise ValueError("Use a separate export directory to preserve the QAT output.")
    setup_runtime(42, 4)
    model, artifact, layers, input_scale, input_zero = extract_model(checkpoint_path)
    output_dir.mkdir(parents=True, exist_ok=True)
    data = ["/* Generated by export_model.py. Do not edit. Define MODEL_DATA_IMPLEMENTATION in ONE C file. */",
            "#ifndef INT8_C_MODEL_DATA_H", "#define INT8_C_MODEL_DATA_H", "#include <stdint.h>",
            f"#define MODEL_ALIGNMENT {alignment}", ""]
    binary, binary_arrays = bytearray(), []
    weight_count = 0
    for layer in layers:
        symbol = "model_" + layer["symbol"]
        arrays = [
            ("weight", "int8_t", layer["weight"], np.dtype("i1"), False),
            ("weight_scale", "float", layer["weight_scales"], np.dtype("<f4"), True),
            ("weight_zero", "int32_t", layer["weight_zero_points"], np.dtype("<i4"), False),
            ("multiplier", "int32_t", layer["multipliers"], np.dtype("<i4"), False),
            ("right_shift", "int32_t", layer["right_shifts"], np.dtype("<i4"), False),
        ]
        for suffix, ctype, values, dtype, floating in arrays:
            name = f"{symbol}_{suffix}"
            array = np.asarray(values, dtype=dtype)
            # Firmware needs Q31 multipliers/shifts only; retain real scales for host analysis.
            if floating:
                data.append("#ifndef MODEL_INTEGER_ONLY")
            data.append(c_array(name, ctype, array, floating))
            if floating:
                data.append("#endif /* !MODEL_INTEGER_ONLY */")
            binary.extend(b"\x00" * (-len(binary) % alignment))
            offset = len(binary)
            blob = array.tobytes(order="C")
            binary.extend(blob)
            binary_arrays.append({"name": name, "offset": offset, "length": len(blob),
                                  "dtype": dtype.str, "shape": list(array.shape),
                                  "endianness": "not_applicable" if dtype.itemsize == 1 else "little",
                                  "sha256": hashlib.sha256(blob).hexdigest()})
        weight_count += layer["weight"].size
    data.append("#endif\n")
    (output_dir / "model_data.h").write_text("\n".join(data), encoding="utf-8")
    (output_dir / "model_data.bin").write_bytes(binary)
    max_elements = max([IMAGE_SIZE ** 2] + [layer["output_elements"] for layer in layers])
    max_activations = (max_elements + alignment - 1) // alignment * alignment
    source_hash = hashlib.sha256(checkpoint_path.read_bytes()).hexdigest()
    gray_values = torch.arange(256, dtype=torch.float32) / 255.0
    normalized_gray = (1.0 - gray_values if artifact["preprocessing"]["input_mode"] == "foreground"
                       else (gray_values - 0.5) / 0.5)
    with torch.inference_mode():
        gray_lut = model.quant(normalized_gray).int_repr().tolist()
    params = [
        "/* Generated model geometry and quantization parameters. */",
        "#ifndef INT8_C_MODEL_PARAM_H", "#define INT8_C_MODEL_PARAM_H",
        '#include "model_data.h"', '#include "model_types.h"',
        "#define MODEL_INPUT_CHANNELS 1", f"#define MODEL_INPUT_HEIGHT {IMAGE_SIZE}", f"#define MODEL_INPUT_WIDTH {IMAGE_SIZE}",
        f"#define MODEL_INPUT_ELEMENTS {IMAGE_SIZE ** 2}", f"#define MODEL_CLASS_COUNT {len(artifact['classes'])}",
        f"#define MODEL_LAYER_COUNT {len(layers)}", f"#define MODEL_MAX_ACTIVATIONS {max_activations}",
        f"#define MODEL_TRACE_ELEMENTS {sum(layer['output_elements'] for layer in layers)}",
        f"#define MODEL_WEIGHT_BYTES {weight_count}",
        "#ifndef MODEL_INTEGER_ONLY",
        f"#define MODEL_INPUT_SCALE {float_literal(input_scale)}",
        f"#define MODEL_OUTPUT_SCALE {float_literal(layers[-1]['output_scale'])}",
        "#endif",
        f"#define MODEL_INPUT_ZERO_POINT {input_zero}",
        f"#define MODEL_OUTPUT_ZERO_POINT {layers[-1]['output_zero_point']}",
        f"#define MODEL_INPUT_FOREGROUND {int(artifact['preprocessing']['input_mode'] == 'foreground')}",
        f'#define MODEL_SOURCE_SHA256 "{source_hash}"',
        '#define MODEL_SOURCE_CHECKPOINT ' + json.dumps(str(checkpoint_path)),
        '#define MODEL_SOURCE_METHOD ' + json.dumps(artifact["method"]),
        "typedef struct {", "    const char *name;", "    int is_conv, relu;",
        "    int in_c, in_h, in_w, out_c, out_h, out_w;", "    int32_t input_zero, output_zero;",
        "#ifndef MODEL_INTEGER_ONLY", "    float input_scale, output_scale;", "#endif",
        "    const int8_t *weight;",
        "#ifndef MODEL_INTEGER_ONLY", "    const float *weight_scale;", "#endif",
        "    const int32_t *weight_zero, *multiplier, *right_shift;",
        "    size_t trace_offset, output_elements;", "} ModelLayer;",
        "extern const ModelLayer model_layers[MODEL_LAYER_COUNT];",
        "extern const char *const model_class_names[MODEL_CLASS_COUNT];",
        "extern const uint8_t model_gray8_to_input[256];",
        "#ifdef MODEL_DATA_IMPLEMENTATION",
        "const uint8_t model_gray8_to_input[256] = {",
        "    " + ", ".join(str(v) for v in gray_lut),
        "};", "const ModelLayer model_layers[MODEL_LAYER_COUNT] = {",
    ]
    for layer in layers:
        symbol = "model_" + layer["symbol"]
        dims = layer["input_shape"] + layer["output_shape"]
        params += ["    {", "        " + json.dumps(layer["name"]) + ", "
                   + f"{int(layer['type'] == 'conv_pool')}, {int(layer['relu'])}, "
                   + ", ".join(map(str, dims)) + ", "
                   + f"{layer['input_zero_point']}, {layer['output_zero_point']},",
                   "#ifndef MODEL_INTEGER_ONLY",
                   f"        {float_literal(layer['input_scale'])}, {float_literal(layer['output_scale'])},",
                   "#endif", f"        {symbol}_weight,",
                   "#ifndef MODEL_INTEGER_ONLY", f"        {symbol}_weight_scale,", "#endif",
                   f"        {symbol}_weight_zero, {symbol}_multiplier, {symbol}_right_shift,",
                   f"        {layer['trace_offset']}, {layer['output_elements']}", "    },"]
    params += ["};", "const char *const model_class_names[MODEL_CLASS_COUNT] = {",
               "    " + ", ".join(json.dumps(c, ensure_ascii=True) for c in artifact["classes"]),
               "};", "#endif", "#endif", ""]
    (output_dir / "model_param.h").write_text("\n".join(params), encoding="utf-8")
    manifest = {
        "format_version": 1, "source_checkpoint": str(checkpoint_path), "source_sha256": source_hash,
        "source_method": artifact["method"], "source_backend": artifact["backend"],
        "torch_version": str(torch.__version__), "model_config": artifact["model_config"],
        "classes": artifact["classes"], "preprocessing": artifact["preprocessing"],
        "input_scale": input_scale, "input_zero_point": input_zero,
        "gray8_to_input_lut": gray_lut, "gray8_lut_bytes": 256,
        "input_shape": [1, IMAGE_SIZE, IMAGE_SIZE], "activation_range": [0, 255], "weight_range": [-128, 127],
        "alignment": alignment, "weight_bytes": weight_count, "binary_bytes": len(binary),
        "workspace_bytes": max_activations * 2, "max_activations": max_activations,
        "trace_elements": sum(layer["output_elements"] for layer in layers),
        "requantization": "round_ties_to_even(accumulator * multiplier / 2**right_shift) + output_zero_point",
        "layers": [{key: value for key, value in layer.items() if key != "weight"} for layer in layers],
        "binary_arrays": binary_arrays,
        "sha256": {name: hashlib.sha256((output_dir / name).read_bytes()).hexdigest()
                   for name in ["model_data.h", "model_param.h", "model_data.bin"]},
    }
    (output_dir / "model_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Exported {len(layers)} layers, {weight_count} INT8 weight bytes → {output_dir}")
    return model, artifact, layers, manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, default=BASE.parent / "qat/outputs/model_int8.pt")
    parser.add_argument("--output-dir", type=Path, default=BASE)
    parser.add_argument("--alignment", type=int, default=16)
    args = parser.parse_args()
    export_model(args.checkpoint, args.output_dir, args.alignment)


if __name__ == "__main__":
    main()

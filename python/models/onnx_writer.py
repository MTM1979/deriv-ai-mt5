"""Minimal ONNX writer and reader for the logistic baseline.

Why hand-write protobuf?  The research pipeline must work on a bare
Python interpreter (this repository is validated on one with no NumPy,
onnx or onnxruntime).  A logistic model is three nodes, so encoding the
protobuf directly is smaller and easier to audit than adding a large
dependency to the critical path.  The resulting file is ordinary ONNX:
``MatMul -> Add -> Softmax`` with float32 initializers.

``describe_model`` parses the same bytes back.  It is intentionally
narrow (no external data, no variable-length sequences) and is used by
the tests to prove the graph binds the expected shapes.
"""

from __future__ import annotations

import struct
from typing import Iterable, Sequence

__all__ = [
    "encode_logistic",
    "describe_model",
    "OnnxFormatError",
]

IR_VERSION = 8
OPSET_VERSION = 13
PRODUCER = "deriv-ai-mt5"


class OnnxFormatError(ValueError):
    pass


# ---------------------------------------------------------------------------
# protobuf primitives
# ---------------------------------------------------------------------------
def _varint(value: int) -> bytes:
    if value < 0:
        value += 1 << 64
    out = bytearray()
    while True:
        chunk = value & 0x7F
        value >>= 7
        if value:
            out.append(chunk | 0x80)
        else:
            out.append(chunk)
            return bytes(out)


def _key(field: int, wire: int) -> bytes:
    return _varint((field << 3) | wire)


def _int(field: int, value: int) -> bytes:
    return _key(field, 0) + _varint(int(value))


def _str(field: int, text: str) -> bytes:
    payload = text.encode("utf-8")
    return _key(field, 2) + _varint(len(payload)) + payload


def _message(field: int, payload: bytes) -> bytes:
    return _key(field, 2) + _varint(len(payload)) + payload


def _packed_floats(field: int, values: Sequence[float]) -> bytes:
    payload = b"".join(struct.pack("<f", float(v)) for v in values)
    return _key(field, 2) + _varint(len(payload)) + payload


def _tensor(name: str, dims: Sequence[int], values: Sequence[float]) -> bytes:
    expected = 1
    for dim in dims:
        expected *= int(dim)
    if expected != len(values):
        raise ValueError(f"tensor '{name}' has {len(values)} values, expected {expected}")
    payload = b"".join(_int(1, int(d)) for d in dims)
    payload += _int(2, 1)  # TensorProto.FLOAT
    payload += _packed_floats(4, values)
    payload += _str(8, name)
    return payload


def _value_info(name: str, dims: Sequence[int]) -> bytes:
    shape = b"".join(_message(1, _int(1, int(d))) for d in dims)
    tensor_type = _int(1, 1)  # elem_type = FLOAT
    tensor_type += _message(2, shape)
    type_proto = _message(1, tensor_type)
    return _str(1, name) + _message(2, type_proto)


def _attribute_int(name: str, value: int) -> bytes:
    # AttributeProto: name=1, i=3, type=20 (INT=2)
    return _str(1, name) + _int(3, int(value)) + _int(20, 2)


def _node(op_type: str, inputs: Sequence[str], outputs: Sequence[str], name: str, extra: bytes = b"") -> bytes:
    payload = b"".join(_str(1, item) for item in inputs)
    payload += b"".join(_str(2, item) for item in outputs)
    payload += _str(3, name)
    payload += _str(4, op_type)
    payload += extra
    return payload


def _graph(
    nodes: Sequence[bytes],
    name: str,
    initializers: Sequence[bytes],
    inputs: Sequence[bytes],
    outputs: Sequence[bytes],
) -> bytes:
    payload = b"".join(_message(1, node) for node in nodes)
    payload += _str(2, name)
    payload += b"".join(_message(5, tensor) for tensor in initializers)
    payload += b"".join(_message(11, info) for info in inputs)
    payload += b"".join(_message(12, info) for info in outputs)
    return payload


def encode_logistic(
    weights: Sequence[float],
    bias: float,
    *,
    output_kind: str = "binary_two",
    producer: str = PRODUCER,
    producer_version: str = "1",
) -> bytes:
    """Encode a single-layer logistic model as ONNX.

    ``weights`` are the *effective* coefficients applied directly to the
    raw, clamped feature vector (standardisation must already be folded
    into them).  ``binary_two`` produces ``[1, 2]`` class probabilities
    via Softmax; ``binary_one`` produces ``[1, 1]`` via Sigmoid.
    """
    count = len(weights)
    if count < 1:
        raise ValueError("weights are empty")
    if not all(_finite(v) for v in weights) or not _finite(bias):
        raise ValueError("weights and bias must be finite")
    if output_kind not in ("binary_two", "binary_one"):
        raise ValueError("output_kind must be 'binary_two' or 'binary_one'")

    if output_kind == "binary_two":
        matrix = [0.0] * count
        for weight in weights:
            matrix.append(float(weight))
        bias_values = [0.0, float(bias)]
        out_dim = 2
    else:
        matrix = [float(w) for w in weights]
        bias_values = [float(bias)]
        out_dim = 1

    nodes = [
        _node("MatMul", ["features", "W"], ["logits"], "matmul"),
        _node("Add", ["logits", "b"], ["biased"], "add"),
    ]
    if output_kind == "binary_two":
        nodes.append(
            _node(
                "Softmax",
                ["biased"],
                ["probability"],
                "softmax",
                _message(5, _attribute_int("axis", 1)),
            )
        )
    else:
        nodes.append(_node("Sigmoid", ["biased"], ["probability"], "sigmoid"))

    graph = _graph(
        nodes,
        "deriv_ai_logistic",
        [
            _tensor("W", [count, out_dim], matrix),
            _tensor("b", [out_dim], bias_values),
        ],
        [_value_info("features", [1, count])],
        [_value_info("probability", [1, out_dim])],
    )
    opset = _str(1, "") + _int(2, OPSET_VERSION)
    model = _int(1, IR_VERSION)
    model += _str(2, producer)
    model += _str(3, producer_version)
    model += _str(6, "logistic baseline for the Deriv multi-asset EA")
    model += _message(7, graph)
    model += _message(8, opset)
    return model


def _finite(value: float) -> bool:
    return value == value and value not in (float("inf"), float("-inf"))


# ---------------------------------------------------------------------------
# Narrow reader used by tests and ``--inspect``
# ---------------------------------------------------------------------------
def _read_varint(data: bytes, position: int) -> tuple[int, int]:
    shift = 0
    value = 0
    while True:
        if position >= len(data):
            raise OnnxFormatError("truncated varint")
        byte = data[position]
        position += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, position
        shift += 7
        if shift > 63:
            raise OnnxFormatError("varint too long")


def _fields(data: bytes) -> Iterable[tuple[int, int, object]]:
    position = 0
    while position < len(data):
        key, position = _read_varint(data, position)
        field = key >> 3
        wire = key & 0x07
        if wire == 0:
            value, position = _read_varint(data, position)
        elif wire == 1:
            if position + 8 > len(data):
                raise OnnxFormatError("truncated fixed64")
            value = data[position:position + 8]
            position += 8
        elif wire == 2:
            length, position = _read_varint(data, position)
            if position + length > len(data):
                raise OnnxFormatError("truncated length-delimited field")
            value = data[position:position + length]
            position += length
        elif wire == 5:
            if position + 4 > len(data):
                raise OnnxFormatError("truncated fixed32")
            value = data[position:position + 4]
            position += 4
        else:
            raise OnnxFormatError(f"unsupported wire type {wire}")
        yield field, wire, value


def _packed_varints(payload: bytes) -> list[int]:
    out: list[int] = []
    position = 0
    while position < len(payload):
        value, position = _read_varint(payload, position)
        out.append(value)
    return out


def _parse_tensor(data: bytes) -> dict:
    dims: list[int] = []
    data_type = 0
    name = ""
    floats: list[float] = []
    for field, wire, value in _fields(data):
        if field == 1:
            if wire == 2:
                dims.extend(_packed_varints(value))  # type: ignore[arg-type]
            else:
                dims.append(int(value))  # type: ignore[arg-type]
        elif field == 2:
            data_type = int(value)  # type: ignore[arg-type]
        elif field == 4:
            if wire == 2:
                payload = value  # type: ignore[assignment]
                if len(payload) % 4:
                    raise OnnxFormatError("float_data is not a multiple of 4")
                floats.extend(struct.unpack("<" + "f" * (len(payload) // 4), payload))
            else:
                floats.append(struct.unpack("<f", value)[0])  # type: ignore[arg-type]
        elif field == 8:
            name = value.decode("utf-8")  # type: ignore[union-attr]
    return {"name": name, "dims": dims, "data_type": data_type, "values": floats}


def _parse_value_info(data: bytes) -> dict:
    name = ""
    dims: list[int] = []
    elem_type = 0
    for field, _, value in _fields(data):
        if field == 1:
            name = value.decode("utf-8")  # type: ignore[union-attr]
        elif field == 2:
            for type_field, _, type_value in _fields(value):  # type: ignore[arg-type]
                if type_field != 1:
                    continue
                for tensor_field, _, tensor_value in _fields(type_value):  # type: ignore[arg-type]
                    if tensor_field == 1:
                        elem_type = int(tensor_value)  # type: ignore[arg-type]
                    elif tensor_field == 2:
                        for shape_field, _, shape_value in _fields(tensor_value):  # type: ignore[arg-type]
                            if shape_field != 1:
                                continue
                            for dim_field, _, dim_value in _fields(shape_value):  # type: ignore[arg-type]
                                if dim_field == 1:
                                    dims.append(int(dim_value))  # type: ignore[arg-type]
    return {"name": name, "elem_type": elem_type, "dims": dims}


def describe_model(data: bytes) -> dict:
    """Parse the subset of ONNX emitted by :func:`encode_logistic`."""
    model: dict = {"ir_version": 0, "producer": "", "graph": {}}
    for field, _, value in _fields(data):
        if field == 1:
            model["ir_version"] = int(value)  # type: ignore[arg-type]
        elif field == 2:
            model["producer"] = value.decode("utf-8")  # type: ignore[union-attr]
        elif field == 7:
            graph = {"nodes": [], "initializers": [], "inputs": [], "outputs": []}
            for gfield, _, gvalue in _fields(value):  # type: ignore[arg-type]
                if gfield == 1:
                    node = {"op_type": "", "inputs": [], "outputs": [], "name": "", "attributes": {}}
                    for nfield, _, nvalue in _fields(gvalue):  # type: ignore[arg-type]
                        if nfield == 1:
                            node["inputs"].append(nvalue.decode("utf-8"))  # type: ignore[union-attr]
                        elif nfield == 2:
                            node["outputs"].append(nvalue.decode("utf-8"))  # type: ignore[union-attr]
                        elif nfield == 3:
                            node["name"] = nvalue.decode("utf-8")  # type: ignore[union-attr]
                        elif nfield == 4:
                            node["op_type"] = nvalue.decode("utf-8")  # type: ignore[union-attr]
                        elif nfield == 5:
                            attrs = {}
                            for afield, _, avalue in _fields(nvalue):  # type: ignore[arg-type]
                                if afield == 1:
                                    attrs["name"] = avalue.decode("utf-8")  # type: ignore[union-attr]
                                elif afield == 3:
                                    attrs["i"] = int(avalue)  # type: ignore[arg-type]
                            if "name" in attrs:
                                node["attributes"][attrs["name"]] = attrs.get("i")
                    graph["nodes"].append(node)  # type: ignore[union-attr]
                elif gfield == 5:
                    graph["initializers"].append(_parse_tensor(gvalue))  # type: ignore[union-attr]
                elif gfield == 11:
                    graph["inputs"].append(_parse_value_info(gvalue))  # type: ignore[union-attr]
                elif gfield == 12:
                    graph["outputs"].append(_parse_value_info(gvalue))  # type: ignore[union-attr]
            model["graph"] = graph
    if model["ir_version"] != IR_VERSION:
        raise OnnxFormatError(f"unexpected ir_version {model['ir_version']}")
    return model

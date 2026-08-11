#!/usr/bin/env python3
"""Source-level operation inventory for production hair shaders.

This intentionally does NOT claim GPU ISA/instruction counts. Godot's shader
compiler and the vendor driver can inline, fold, vectorize, or remove source
operations. The inventory is used alongside runtime scaling tests to explain
where the production tiers differ structurally.
"""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path

TIERS = {
    "approx": "assets/hair/materials/shaders/hair_approx.gdshader",
    "fast": "assets/hair/materials/shaders/hair_marschner_unity_fast.gdshader",
    "cinematic": "assets/hair/materials/shaders/hair_marschner_cinematic.gdshader",
    "reference": "assets/hair/materials/shaders/hair.gdshader",
}

INCLUDE_RE = re.compile(r'^\s*#include\s+"([^"]+)"', re.MULTILINE)
BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
LINE_COMMENT_RE = re.compile(r"//.*?$", re.MULTILINE)
SAMPLER_RE = re.compile(r"\buniform\s+sampler(2D|3D|Cube)\s+([A-Za-z_]\w*)")
TEXTURE_RE = re.compile(r"\b(texture|textureLod|textureGrad|texelFetch)\s*\(\s*([A-Za-z_]\w*)")
TEXTURE_SIZE_RE = re.compile(r"\btextureSize\s*\(\s*([A-Za-z_]\w*)")

SPECIAL_FUNCTIONS = (
    "exp", "exp2", "log", "log2", "pow", "sqrt", "inversesqrt",
    "sin", "cos", "tan", "asin", "acos", "atan",
)
VECTOR_FUNCTIONS = ("normalize", "length", "distance", "dot", "cross", "reflect", "refract")
SHAPING_FUNCTIONS = ("abs", "min", "max", "clamp", "mix", "step", "smoothstep", "fract", "floor", "ceil")


def strip_comments(text: str) -> str:
    return LINE_COMMENT_RE.sub("", BLOCK_COMMENT_RE.sub("", text))


def expand_file(path: Path, stack: tuple[Path, ...] = ()) -> tuple[str, list[str]]:
    path = path.resolve()
    if path in stack:
        chain = " -> ".join(str(p) for p in (*stack, path))
        raise RuntimeError(f"include cycle: {chain}")
    text = path.read_text(encoding="utf-8")
    includes: list[str] = []

    def replace(match: re.Match[str]) -> str:
        relative = match.group(1)
        include_path = (path.parent / relative).resolve()
        expanded, nested = expand_file(include_path, (*stack, path))
        includes.append(str(include_path))
        includes.extend(nested)
        return f"\n// BEGIN EXPANDED {include_path}\n{expanded}\n// END EXPANDED {include_path}\n"

    return INCLUDE_RE.sub(replace, text), includes


def function_counts(source: str, names: tuple[str, ...]) -> dict[str, int]:
    result: dict[str, int] = {}
    for name in names:
        count = len(re.findall(rf"\b{re.escape(name)}\s*\(", source))
        if count:
            result[name] = count
    return result


def lexical_operator_counts(source: str) -> dict[str, int]:
    # Lexical token counts only; declarations, unary operators, compound
    # expressions and compiler lowering make these unsuitable as ISA counts.
    return {
        "multiply_tokens": len(re.findall(r"(?<![*/])\*(?![=/])", source)),
        "divide_tokens": len(re.findall(r"(?<!/)\/(?![=/])", source)),
        "plus_tokens": len(re.findall(r"(?<!\+)\+(?![+=])", source)),
        "minus_tokens": len(re.findall(r"(?<!-)-(?![-=>])", source)),
    }


def inventory(project: Path, tier: str, shader_rel: str) -> dict:
    shader_path = project / shader_rel
    expanded, includes = expand_file(shader_path)
    clean = strip_comments(expanded)

    samplers = Counter()
    sampler_names: dict[str, str] = {}
    for sampler_type, name in SAMPLER_RE.findall(clean):
        key = sampler_type.lower()
        samplers[key] += 1
        sampler_names[name] = key

    texture_calls = Counter()
    texture_calls_by_sampler = Counter()
    for call_name, sampler_name in TEXTURE_RE.findall(clean):
        texture_calls[call_name] += 1
        texture_calls_by_sampler[sampler_name] += 1
    for sampler_name in TEXTURE_SIZE_RE.findall(clean):
        texture_calls["textureSize"] += 1
        texture_calls_by_sampler[f"{sampler_name}::size"] += 1

    special = function_counts(clean, SPECIAL_FUNCTIONS)
    vector = function_counts(clean, VECTOR_FUNCTIONS)
    shaping = function_counts(clean, SHAPING_FUNCTIONS)

    unique_includes = []
    seen = set()
    for include in includes:
        rel = str(Path(include).relative_to(project.resolve()))
        if rel not in seen:
            seen.add(rel)
            unique_includes.append(rel)

    return {
        "tier": tier,
        "shader": shader_rel,
        "expanded_source_lines": len(expanded.splitlines()),
        "includes": unique_includes,
        "sampler_declarations": dict(sorted(samplers.items())),
        "sampler_names": sampler_names,
        "texture_calls": dict(sorted(texture_calls.items())),
        "texture_calls_by_sampler": dict(sorted(texture_calls_by_sampler.items())),
        "special_function_calls": special,
        "special_function_total": sum(special.values()),
        "vector_function_calls": vector,
        "vector_function_total": sum(vector.values()),
        "shaping_function_calls": shaping,
        "shaping_function_total": sum(shaping.values()),
        "lexical_operator_tokens": lexical_operator_counts(clean),
        "caveat": "Source inventory only; not post-compile GPU ISA or executed dynamic instruction counts.",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", type=Path, default=Path("."))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--pretty", action="store_true")
    args = parser.parse_args()

    project = args.project.resolve()
    payload = {
        "schema": "production_hair_shader_source_inventory_v1",
        "project": str(project),
        "tiers": {tier: inventory(project, tier, path) for tier, path in TIERS.items()},
        "methodology": {
            "include_expansion": "Recursively expands Godot #include directives before counting.",
            "texture_counts": "Counts explicit source texture/textureLod/textureGrad/texelFetch calls and sampler declarations.",
            "alu_proxy": "Reports lexical arithmetic tokens and math intrinsic calls only. Runtime light-count and resolution scaling are the primary ALU/fragment-cost evidence.",
            "warning": "Do not interpret any source count as vendor shader ISA, cycle count, or executed instruction count.",
        },
    }
    rendered = json.dumps(payload, indent=2 if args.pretty else None, sort_keys=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

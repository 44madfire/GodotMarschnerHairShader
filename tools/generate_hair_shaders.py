#!/usr/bin/env python3
"""Deterministic generator for the production Marschner hair shader wrappers.

Generates the six production .gdshader wrappers (and the shared Approx body
include) from canonical templates under tools/templates/. The generator is
stdlib-only and fully deterministic: identical template inputs always produce
identical bytes, so ``--check`` can detect drift between the templates and the
checked-in addon files.

Generated files
---------------
addons/marschner_hair/shaders/hair_approx.gdshader
addons/marschner_hair/shaders/hair_approx_a2c.gdshader
addons/marschner_hair/shaders/hair_approx_body.gdshaderinc
addons/marschner_hair/shaders/hair_marschner_unity_fast.gdshader
addons/marschner_hair/shaders/hair_marschner_unity_fast_a2c.gdshader
addons/marschner_hair/shaders/hair_marschner_cinematic.gdshader
addons/marschner_hair/shaders/hair_marschner_cinematic_a2c.gdshader

The Reference/benchmark shader sources under assets/hair and benchmark/ are
deliberately not generated or touched; they keep their own copies of the
shared includes.

Template format
---------------
Each template file contains a documentation header followed by marker-delimited
sections. Only the section content is emitted:

    // >>> WRAPPER
    ...literal wrapper content with variant tokens...
    // <<< WRAPPER

    // >>> BODY            (Approx template only)
    ...shared body content, written verbatim...
    // <<< BODY

Variant tokens substituted by the generator:

    {{RENDER_MODE}}        normal: cull_disabled, world_vertex_coords
                           a2c:    cull_disabled, world_vertex_coords, alpha_to_coverage
    {{BAYER_PHASE_INDEX}}  normal: the Coverage group (bayer_phase_index)
                           a2c:    omitted
    {{A2C_DEFINE}}         a2c:    #define HAIR_COVERAGE_ALPHA_TO_COVERAGE
                           normal: omitted
    {{SHOW_CARDS_DOC}}     normal: "without coverage thinning" doc comment
                           a2c:    "at full alpha" doc comment
    {{TIER_COMMENT}}       normal: the production tier comment block
                           a2c:    omitted

The Approx coverage block lives in the Approx template's BODY section and
switches on HAIR_COVERAGE_ALPHA_TO_COVERAGE: the normal wrapper discards below
the ordered-dither threshold, the alpha-to-coverage wrapper writes ALPHA.

Usage
-----
    python3 tools/generate_hair_shaders.py            # write generated files
    python3 tools/generate_hair_shaders.py --check    # verify no drift
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
TEMPLATE_DIR = REPO_ROOT / "tools" / "templates"
SHADER_DIR = REPO_ROOT / "addons" / "marschner_hair" / "shaders"

# Variant tokens -------------------------------------------------------------

RENDER_MODE_NORMAL = "cull_disabled, world_vertex_coords"
RENDER_MODE_A2C = "cull_disabled, world_vertex_coords, alpha_to_coverage"

A2C_DEFINE = "#define HAIR_COVERAGE_ALPHA_TO_COVERAGE\n"

SHOW_CARDS_DOC_NORMAL = (
    "/** Renders the full card geometry without coverage thinning. Use this to "
    "inspect card placement and UVs; disable it for final hair rendering. */"
)
SHOW_CARDS_DOC_A2C = (
    "/** Renders the full card geometry at full alpha. Use this to inspect card "
    "placement and UVs; disable it for final hair rendering. */"
)

FAST_TIER_COMMENT = (
    "// Production Fast Marschner tier: a coherent Unity HDRP Standard-style model.\n"
    "// M = separable Unity Gaussian, N = Unity preintegrated RGB azimuthal LUT,\n"
    "// A = Unity fixed-h analytic Fresnel/Beer attenuation. This shader intentionally\n"
    "// omits the baseline's non-separable d'Eon longitudinal cone/width machinery.\n"
    "//\n"
    "// Uniforms remain in this top-level wrapper (rather than only in the body\n"
    "// include) because Godot 4.7 runtime uniform reflection is unreliable for\n"
    "// interfaces declared solely through nested shader includes.\n"
    "\n"
)

CINEMATIC_TIER_COMMENT = (
    "// Production Cinematic Marschner tier.\n"
    "// The high-tier baseline's non-separable azimuth-dependent cone/width and\n"
    "// analytic N/A behavior are preserved. Only the expensive d'Eon longitudinal\n"
    "// kernel is replaced by a generic angle-domain log-Q 3D LUT sampled once for\n"
    "// each of R/TT/TRT, with a narrow-beta analytic fallback/transition.\n"
    "//\n"
    "// Uniforms remain in this top-level wrapper because Godot 4.7 runtime uniform\n"
    "// reflection is unreliable for interfaces declared solely through includes.\n"
    "\n"
)

BAYER_PHASE_INDEX_BLOCK = (
    "group_uniforms Coverage;\n"
    "/** Selects one of the 16 ordered-dither phases. Phase 0 is stable; "
    "HairCoverageController advances this once per rendered frame only for TAA temporal coverage. */\n"
    "uniform int bayer_phase_index : hint_range(0, 15) = 0;\n"
    "group_uniforms;\n"
    "\n"
)

# Template section markers ---------------------------------------------------

WRAPPER_START = "// >>> WRAPPER"
WRAPPER_END = "// <<< WRAPPER"
BODY_START = "// >>> BODY"
BODY_END = "// <<< BODY"

# Template specs: template file -> generated outputs -------------------------

TEMPLATE_SPECS = (
    {
        "template": "hair_approx.gdshader.tmpl",
        "outputs": (
            ("hair_approx.gdshader", False),
            ("hair_approx_a2c.gdshader", True),
        ),
        "body_output": "hair_approx_body.gdshaderinc",
        "tier_comment": "",
    },
    {
        "template": "hair_marschner_unity_fast.gdshader.tmpl",
        "outputs": (
            ("hair_marschner_unity_fast.gdshader", False),
            ("hair_marschner_unity_fast_a2c.gdshader", True),
        ),
        "body_output": None,
        "tier_comment": FAST_TIER_COMMENT,
    },
    {
        "template": "hair_marschner_cinematic.gdshader.tmpl",
        "outputs": (
            ("hair_marschner_cinematic.gdshader", False),
            ("hair_marschner_cinematic_a2c.gdshader", True),
        ),
        "body_output": None,
        "tier_comment": CINEMATIC_TIER_COMMENT,
    },
)


def parse_template(path: Path) -> tuple[str, str]:
    """Split a template file into (wrapper_section, body_section).

    Sections are delimited by the marker comments above. Content outside the
    markers (the documentation header) is ignored. Both returned strings end
    with exactly one trailing newline.
    """
    text = path.read_text(encoding="utf-8")
    wrapper_lines: list[str] = []
    body_lines: list[str] = []
    section: str | None = None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped == WRAPPER_START:
            section = "wrapper"
            continue
        if stripped == WRAPPER_END:
            section = None
            continue
        if stripped == BODY_START:
            section = "body"
            continue
        if stripped == BODY_END:
            section = None
            continue
        if section == "wrapper":
            wrapper_lines.append(line)
        elif section == "body":
            body_lines.append(line)
    return "\n".join(wrapper_lines) + "\n", "\n".join(body_lines) + "\n"


def render_wrapper(wrapper_text: str, *, alpha_to_coverage: bool, tier_comment: str) -> str:
    """Substitute the variant tokens into a wrapper section."""
    substitutions = {
        "{{RENDER_MODE}}": RENDER_MODE_A2C if alpha_to_coverage else RENDER_MODE_NORMAL,
        "{{BAYER_PHASE_INDEX}}": "" if alpha_to_coverage else BAYER_PHASE_INDEX_BLOCK,
        "{{A2C_DEFINE}}": A2C_DEFINE if alpha_to_coverage else "",
        "{{SHOW_CARDS_DOC}}": SHOW_CARDS_DOC_A2C if alpha_to_coverage else SHOW_CARDS_DOC_NORMAL,
        "{{TIER_COMMENT}}": "" if alpha_to_coverage else tier_comment,
    }
    for token, value in substitutions.items():
        wrapper_text = wrapper_text.replace(token, value)
    return wrapper_text


def generate_all() -> dict[Path, bytes]:
    """Return {output_path: content_bytes} for every generated file."""
    generated: dict[Path, bytes] = {}
    for spec in TEMPLATE_SPECS:
        template_path = TEMPLATE_DIR / spec["template"]
        if not template_path.is_file():
            raise FileNotFoundError(f"missing template: {template_path}")
        wrapper_text, body_text = parse_template(template_path)
        for filename, alpha_to_coverage in spec["outputs"]:
            content = render_wrapper(
                wrapper_text,
                alpha_to_coverage=alpha_to_coverage,
                tier_comment=spec["tier_comment"],
            )
            generated[SHADER_DIR / filename] = content.encode("utf-8")
        if spec["body_output"] is not None:
            generated[SHADER_DIR / spec["body_output"]] = body_text.encode("utf-8")
    return generated


def write_all(generated: dict[Path, bytes]) -> None:
    for path, content in sorted(generated.items()):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        print(f"wrote {path.relative_to(REPO_ROOT)}")


def check_all(generated: dict[Path, bytes]) -> int:
    drift: list[str] = []
    for path, content in sorted(generated.items()):
        relative = path.relative_to(REPO_ROOT)
        if not path.is_file():
            drift.append(f"missing: {relative}")
        elif path.read_bytes() != content:
            drift.append(f"drift:   {relative}")
    if drift:
        print("generated shaders are out of sync with templates:", file=sys.stderr)
        for entry in drift:
            print(f"  {entry}", file=sys.stderr)
        return 1
    print(f"ok: {len(generated)} generated shader files match their templates")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify generated files match templates without writing; exit 1 on drift",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    generated = generate_all()
    if args.check:
        return check_all(generated)
    write_all(generated)
    return 0


if __name__ == "__main__":
    sys.exit(main())
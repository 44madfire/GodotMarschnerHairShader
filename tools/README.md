# Production Hair Shader Generator

`generate_hair_shaders.py` deterministically generates the six production
Marschner hair shader wrappers (plus the shared Approx body include) from
canonical templates in `templates/`.

## Generated files

| Template | Generated files |
| --- | --- |
| `templates/hair_approx.gdshader.tmpl` | `addons/marschner_hair/shaders/hair_approx.gdshader`<br>`addons/marschner_hair/shaders/hair_approx_a2c.gdshader`<br>`addons/marschner_hair/shaders/hair_approx_body.gdshaderinc` |
| `templates/hair_marschner_unity_fast.gdshader.tmpl` | `addons/marschner_hair/shaders/hair_marschner_unity_fast.gdshader`<br>`addons/marschner_hair/shaders/hair_marschner_unity_fast_a2c.gdshader` |
| `templates/hair_marschner_cinematic.gdshader.tmpl` | `addons/marschner_hair/shaders/hair_marschner_cinematic.gdshader`<br>`addons/marschner_hair/shaders/hair_marschner_cinematic_a2c.gdshader` |

The Reference/benchmark shader sources under `assets/hair` and `benchmark/`
are intentionally not generated or touched; they keep their own copies of the
shared includes.

## Usage

```sh
# Regenerate the addon shader files from the templates.
python3 tools/generate_hair_shaders.py

# Verify the checked-in files match the templates (exit 1 on drift).
python3 tools/generate_hair_shaders.py --check
```

The generator is stdlib-only (Python 3.10+), root-independent (paths resolve
from the script location, not the working directory), and deterministic:
identical templates always produce identical bytes with LF newlines and a
single trailing newline, so `--check` is a reliable drift detector.

## Template format

Each template file has a documentation header followed by marker-delimited
sections. Only the section content is emitted:

```glsl
// >>> WRAPPER
...literal wrapper content with variant tokens...
// <<< WRAPPER

// >>> BODY            (Approx template only)
...shared body content, written verbatim...
// <<< BODY
```

The WRAPPER section is the literal top-level interface: `shader_type`,
`render_mode`, uniforms, varyings, and includes stay in the wrapper so Godot
4.7 runtime uniform reflection remains reliable. The Approx BODY section is
the shared vertex/fragment/light implementation written verbatim into
`hair_approx_body.gdshaderinc`.

### Variant tokens

| Token | Normal wrapper | Alpha-to-coverage wrapper |
| --- | --- | --- |
| `{{RENDER_MODE}}` | `cull_disabled, world_vertex_coords` | `cull_disabled, world_vertex_coords, alpha_to_coverage` |
| `{{BAYER_PHASE_INDEX}}` | the `Coverage` group (`bayer_phase_index`) | omitted |
| `{{A2C_DEFINE}}` | omitted | `#define HAIR_COVERAGE_ALPHA_TO_COVERAGE` |
| `{{SHOW_CARDS_DOC}}` | "without coverage thinning" doc comment | "at full alpha" doc comment |
| `{{TIER_COMMENT}}` | the production tier comment block | omitted |

The Approx coverage block lives in the Approx template's BODY section and
switches on `HAIR_COVERAGE_ALPHA_TO_COVERAGE`: the normal wrapper discards
below the ordered-dither threshold, the alpha-to-coverage wrapper writes
`ALPHA`. Fast/Cinematic use the same compile-time switch inside their
hand-maintained body includes.

## Editing workflow

1. Edit the template (never the generated addon file directly).
2. Run `python3 tools/generate_hair_shaders.py` to regenerate.
3. Run `python3 tools/generate_hair_shaders.py --check` to confirm no drift.
4. Run a Godot headless import to confirm the shaders still compile.
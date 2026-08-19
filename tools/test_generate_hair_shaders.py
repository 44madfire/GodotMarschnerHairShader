"""Focused tests for tools/generate_hair_shaders.py.

Run with: python3 -m pytest tools/test_generate_hair_shaders.py
"""

import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_hair_shaders as gen

REPO_ROOT = Path(__file__).resolve().parents[1]
GENERATOR = REPO_ROOT / "tools" / "generate_hair_shaders.py"


def test_check_passes_on_repo() -> None:
    result = subprocess.run(
        [sys.executable, str(GENERATOR), "--check"],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0
    assert "ok: 7 generated shader files match their templates" in result.stdout


def test_generated_output_matches_checked_in_files() -> None:
    generated = gen.generate_all()
    assert len(generated) == 7
    for path, content in generated.items():
        assert path.is_file(), f"missing generated file {path}"
        assert path.read_bytes() == content


def test_missing_wrapper_section_raises(tmp_path: Path) -> None:
    template = tmp_path / "bad.tmpl"
    template.write_text("// no wrapper markers here\n", encoding="utf-8")
    with pytest.raises(gen.TemplateError, match="missing WRAPPER section markers"):
        gen.parse_template(template)


def test_empty_wrapper_section_raises(tmp_path: Path) -> None:
    template = tmp_path / "bad.tmpl"
    template.write_text("// >>> WRAPPER\n// <<< WRAPPER\n", encoding="utf-8")
    with pytest.raises(gen.TemplateError, match="WRAPPER section is empty"):
        gen.parse_template(template)


def test_unbalanced_body_markers_raise(tmp_path: Path) -> None:
    template = tmp_path / "bad.tmpl"
    template.write_text(
        "// >>> WRAPPER\nshader_type spatial;\n// <<< WRAPPER\n// >>> BODY\n",
        encoding="utf-8",
    )
    with pytest.raises(gen.TemplateError, match="unbalanced BODY section markers"):
        gen.parse_template(template)


def test_unresolved_wrapper_token_raises() -> None:
    with pytest.raises(
        gen.TemplateError,
        match=r"unresolved template tokens in WRAPPER section: \{\{RENDER_MDOE\}\}",
    ):
        gen.render_wrapper(
            "render_mode {{RENDER_MDOE}};",
            alpha_to_coverage=False,
            tier_comment="",
        )


def test_unresolved_body_token_raises(tmp_path: Path, monkeypatch) -> None:
    template_dir = tmp_path / "templates"
    shader_dir = tmp_path / "shaders"
    template_dir.mkdir()
    shader_dir.mkdir()
    template = template_dir / "hair_approx.gdshader.tmpl"
    template.write_text(
        "// >>> WRAPPER\nshader_type spatial;\n// <<< WRAPPER\n"
        "// >>> BODY\nvoid fragment() { float x = {{UNKNOWN}}; }\n// <<< BODY\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(gen, "TEMPLATE_DIR", template_dir)
    monkeypatch.setattr(gen, "SHADER_DIR", shader_dir)
    with pytest.raises(
        gen.TemplateError,
        match=r"unresolved template tokens in BODY section: \{\{UNKNOWN\}\}",
    ):
        gen.generate_all()


def test_missing_required_body_raises(tmp_path: Path, monkeypatch) -> None:
    template_dir = tmp_path / "templates"
    shader_dir = tmp_path / "shaders"
    template_dir.mkdir()
    shader_dir.mkdir()
    template = template_dir / "hair_approx.gdshader.tmpl"
    template.write_text(
        "// >>> WRAPPER\nshader_type spatial;\n// <<< WRAPPER\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(gen, "TEMPLATE_DIR", template_dir)
    monkeypatch.setattr(gen, "SHADER_DIR", shader_dir)
    with pytest.raises(gen.TemplateError, match="missing or empty required BODY section"):
        gen.generate_all()
"""Tests for the layered config system.

Priority: defaults < config.yaml < config.{env}.yaml < env vars.
"""

from __future__ import annotations

from pathlib import Path

from app.core.config import Settings, _build_values, _load_yaml


class TestLoadYaml:
    """_load_yaml — low-level helper."""

    def test_reads_existing_file(self, tmp_path: Path):
        path = tmp_path / "cfg.yaml"
        path.write_text("debug: true\napp_name: test\n")
        result = _load_yaml(path)
        assert result == {"debug": True, "app_name": "test"}

    def test_returns_empty_for_missing_file(self, tmp_path: Path):
        result = _load_yaml(tmp_path / "nope.yaml")
        assert result == {}


class TestBuildValues:
    """_build_values — merges general + env-scoped + env vars."""

    def test_general_config_loaded(self, monkeypatch, tmp_path: Path):
        monkeypatch.chdir(tmp_path)
        (tmp_path / "config.yaml").write_text("app_name: from_general\n")
        monkeypatch.setenv("APP_ENV", "dev")
        assert _build_values()["app_name"] == "from_general"

    def test_env_scoped_overrides_general(self, monkeypatch, tmp_path: Path):
        monkeypatch.chdir(tmp_path)
        monkeypatch.delenv("APP_NAME", raising=False)
        monkeypatch.delenv("LOG_LEVEL", raising=False)
        (tmp_path / "config.yaml").write_text("app_name: general\nlog_level: INFO\n")
        (tmp_path / "config.dev.yaml").write_text("app_name: dev_scoped\n")
        monkeypatch.setenv("APP_ENV", "dev")
        vals = _build_values()
        assert vals["app_name"] == "dev_scoped"  # overridden
        assert vals["log_level"] == "INFO"  # untouched by env-scoped

    def test_env_scoped_only_applied_for_matching_app_env(self, monkeypatch, tmp_path: Path):
        monkeypatch.chdir(tmp_path)
        (tmp_path / "config.yaml").write_text("app_name: general\n")
        (tmp_path / "config.prod.yaml").write_text("app_name: prod\n")
        monkeypatch.setenv("APP_ENV", "dev")
        # prod file should be ignored when APP_ENV=dev
        assert _build_values()["app_name"] == "general"

    def test_missing_env_scoped_silently_ignored(self, monkeypatch, tmp_path: Path):
        monkeypatch.chdir(tmp_path)
        (tmp_path / "config.yaml").write_text("app_name: general\n")
        monkeypatch.setenv("APP_ENV", "staging")
        assert _build_values()["app_name"] == "general"


class TestSettings:
    """Settings class — env vars trump everything."""

    def test_field_default(self):
        s = Settings()
        assert isinstance(s.app_name, str)
        assert len(s.app_name) > 0
        assert s.app_name.endswith("API")

    def test_env_var_overrides_everything(self, monkeypatch, tmp_path: Path):
        """Env var beats field default and YAML files."""
        monkeypatch.chdir(tmp_path)
        (tmp_path / "config.yaml").write_text("app_name: from_yaml\n")
        monkeypatch.setenv("APP_NAME", "from_env")
        monkeypatch.setenv("APP_ENV", "dev")
        s = Settings(**_build_values())
        # Env var wins because pydantic-settings checks it AFTER __init__
        assert s.app_name == "from_env"

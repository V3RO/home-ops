#!/usr/bin/env python3
"""Render the Talos config patches that can't be static plain YAML because
they depend on the Image Factory schematic ID or embed whole manifest
files as inline-manifest strings:

  - generated/install-image.yaml            UnattendedInstallConfig
  - generated/cilium-inline-manifests.yaml  KubeInlineManifestConfig

Reads the schematic ID from $SCHEMATIC_ID or generated/schematic-id.txt
(written by `make schematic-id` / scripts/schematic-id.sh).
"""
import os
import pathlib
import textwrap

ROOT = pathlib.Path(__file__).resolve().parent.parent
GENERATED = ROOT / "generated"
GENERATED.mkdir(exist_ok=True)


def schematic_id() -> str:
    env_value = os.environ.get("SCHEMATIC_ID")
    if env_value:
        return env_value.strip()
    schematic_file = GENERATED / "schematic-id.txt"
    if not schematic_file.exists():
        raise SystemExit(
            "No schematic ID found. Run `make schematic-id` first, or set "
            "SCHEMATIC_ID in the environment."
        )
    return schematic_file.read_text().strip()


def render_install_image() -> None:
    version = os.environ.get("TALOS_VERSION", "v1.14.0")
    image = f"factory.talos.dev/metal-installer/{schematic_id()}:{version}"
    (GENERATED / "install-image.yaml").write_text(
        "apiVersion: v1alpha1\n"
        "kind: UnattendedInstallConfig\n"
        "installer:\n"
        f"  image: {image}\n"
    )


def render_cilium_inline_manifests() -> None:
    install_yaml = (ROOT / "bootstrap" / "cilium" / "install.yaml").read_text()
    values_yaml = (ROOT / "bootstrap" / "cilium" / "values.yaml").read_text()

    install_block = textwrap.indent(install_yaml, " " * 2)
    values_block = textwrap.indent(values_yaml, " " * 6)

    content = (
        "apiVersion: v1alpha1\n"
        "kind: KubeInlineManifestConfig\n"
        "name: cilium-bootstrap\n"
        "manifest: |\n"
        f"{install_block}\n"
        "---\n"
        "apiVersion: v1alpha1\n"
        "kind: KubeInlineManifestConfig\n"
        "name: cilium-values\n"
        "manifest: |\n"
        "  apiVersion: v1\n"
        "  kind: ConfigMap\n"
        "  metadata:\n"
        "    name: cilium-values\n"
        "    namespace: kube-system\n"
        "  data:\n"
        "    values.yaml: |\n"
        f"{values_block}\n"
    )
    (GENERATED / "cilium-inline-manifests.yaml").write_text(content)


if __name__ == "__main__":
    render_install_image()
    render_cilium_inline_manifests()
    print(
        "Rendered generated/install-image.yaml and "
        "generated/cilium-inline-manifests.yaml"
    )

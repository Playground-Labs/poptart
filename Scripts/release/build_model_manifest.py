#!/usr/bin/env python3
"""Describe each runtime model file in an unsigned candidate manifest; never extract archives in the app."""
import argparse
import json
import re
import struct
import sys
import unicodedata
from pathlib import Path
from urllib.parse import quote, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from model_files import model_inventory, summary, validate_cleanup_layout

LICENSE_URLS = {'CC-BY-4.0': 'https://creativecommons.org/licenses/by/4.0/',
                'Apache-2.0': 'https://www.apache.org/licenses/LICENSE-2.0',
                'MIT': 'https://opensource.org/license/mit'}


def validate_release_models(pack, config):
    """Development packs may omit capabilities; a shipping pack must satisfy the model ADRs."""
    if config.get('releaseStatus') != 'release':
        return
    cleanup = pack / 'cleanup'
    base = cleanup / 'base' if (cleanup / 'base').is_dir() else cleanup
    model = json.loads((base / 'config.json').read_text())
    quantization = config['cleanup'].get('quantization', {})
    expected = dict(bits=4, group_size=quantization.get('groupSize'), mode='affine')
    if (quantization.get('bits') != 4 or quantization.get('mode') != 'affine'
            or type(expected['group_size']) is not int or expected['group_size'] <= 0
            or config['cleanup'].get('baseModel') != 'Qwen/Qwen3.5-2B'
            or model.get('model_type') != 'qwen3_5'
            or any(model.get('text_config', {}).get(key) != value for key, value in
                   {'hidden_size': 2048, 'num_hidden_layers': 24, 'intermediate_size': 6144}.items())
            or model.get('quantization') != expected
            or model.get('quantization_config', expected) != expected):
        raise ValueError('release Cleanup must use the declared four-bit affine Qwen base')
    tensors = {}
    for path in sorted(base.rglob('*.safetensors')):
        with path.open('rb') as file:
            prefix = file.read(8)
            length = struct.unpack('<Q', prefix)[0] if len(prefix) == 8 else 0
            if not 0 < length <= min(path.stat().st_size - 8, 100_000_000):
                raise ValueError('invalid safetensors header')
            header = json.loads(file.read(length))
        header.pop('__metadata__', None)
        if tensors.keys() & header.keys():
            raise ValueError('duplicate Cleanup base tensor')
        tensors.update(header)
    matrices = {name: value for name, value in tensors.items()
                if name.endswith('.weight') and len(value.get('shape', [])) == 2}
    if not matrices:
        raise ValueError('quantized Cleanup weight matrices required')
    for name, weight in matrices.items():
        rows, packed_columns = weight['shape']
        columns = packed_columns * 8  # Eight four-bit weights per uint32.
        scales = tensors.get(name.removesuffix('.weight') + '.scales', {})
        biases = tensors.get(name.removesuffix('.weight') + '.biases', {})
        if (any(type(value) is not int or value <= 0 for value in weight['shape'])
                or weight.get('dtype') != 'U32' or columns % expected['group_size']
                or any(value.get('shape') != [rows, columns // expected['group_size']]
                       or value.get('dtype') not in ('F16', 'BF16', 'F32') for value in (scales, biases))):
            raise ValueError('Cleanup weight packing does not match four-bit affine quantization')
    ctc = pack / 'recognition/ctc'
    for name in ('MelSpectrogram.mlmodelc', 'AudioEncoder.mlmodelc'):
        for component in ('coremldata.bin', 'model.mil', 'metadata.json', 'weights/weight.bin'):
            path = ctc / name / component
            if not path.is_file() or path.stat().st_size <= 0:
                raise ValueError('complete CTC vocabulary model bundles required for release')
    for name in ('vocab.json', 'tokenizer.json'):
        value = json.loads((ctc / name).read_text())
        if not isinstance(value, (dict, list)) or not value:
            raise ValueError('CTC vocabulary and tokenizer JSON required for release')


def artifact_license(relative, role, config):
    component = config['recognition']['vad'] if relative.startswith('vad/') else config[role]
    name = component['license']
    return dict(name=name, url=LICENSE_URLS[name])


def validate_manifest_header(manifest):
    identity = manifest.get('identity')
    # Foundation's alphanumerics includes Unicode letters, marks, and numbers.
    if not isinstance(identity, str) or not identity or any(
            ch not in '-_' and unicodedata.category(ch)[0] not in 'LMN' for ch in identity):
        raise ValueError('safe nonempty model pack identity required')
    versions = {}
    for field in ('version', 'minimumApplicationVersion', 'maximumApplicationVersion'):
        value = manifest.get(field)
        if not isinstance(value, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+)+', value):
            raise ValueError(f'numeric dotted {field} required')
        components = []
        for part in value.split('.'):
            part = part.lstrip('0') or '0'
            if len(part) > 19 or int(part) > 2**63 - 1:
                raise ValueError(f'{field} component exceeds native Int range')
            components.append(int(part))
        while len(components) > 1 and components[-1] == 0:
            components.pop()
        versions[field] = components
    if versions['minimumApplicationVersion'] > versions['maximumApplicationVersion']:
        raise ValueError('reversed application compatibility range')


def validate_manifest(manifest, pack, ceiling, config):
    validate_manifest_header(manifest)
    validate_release_models(pack, config)
    if manifest.get('exampleOnly') or type(manifest.get('cleanupTokenCeiling')) is not int or manifest['cleanupTokenCeiling'] != ceiling or ceiling <= 0:
        raise ValueError('manifest must carry the measured Cleanup ceiling')
    expected = {name: dict(role=role, license=artifact_license(name, role, config), **value)
                for role in ('recognition', 'cleanup') for name, value in model_inventory(pack, role).items()}
    validate_cleanup_layout({name.removeprefix('cleanup/'): value for name, value in expected.items()
                             if name.startswith('cleanup/')})
    actual = {}
    for artifact in manifest.get('artifacts', []):
        path = artifact.get('relativePath')
        if path in actual or type(artifact.get('byteSize')) is not int:
            raise ValueError('duplicate path or invalid artifact size')
        url = urlsplit(artifact.get('url', ''))
        if url.scheme != 'https' or not url.hostname or url.username or url.password:
            raise ValueError('HTTPS artifact URL required')
        license = artifact.get('license', {})
        if not isinstance(license.get('name'), str) or not license['name'].strip() or urlsplit(license.get('url', '')).scheme != 'https':
            raise ValueError('artifact license and HTTPS license URL required')
        actual[path] = {key: artifact.get(key) for key in ('role', 'byteSize', 'sha256', 'license')}
    if actual != expected:
        raise ValueError('manifest files differ from shipping model files')


def build(pack, config, base_url, version, minimum, maximum, ceiling):
    manifest = dict(identity='poptart-model-pack', version=version,
                    minimumApplicationVersion=minimum, maximumApplicationVersion=maximum)
    validate_manifest_header(manifest)
    validate_release_models(pack, config)
    url = urlsplit(base_url)
    if url.scheme != 'https' or not url.netloc or url.username or url.password or url.query or url.fragment:
        raise ValueError('public HTTPS base URL without credentials, query or fragment required')
    if type(ceiling) is not int or ceiling <= 0:
        raise ValueError('explicit positive candidate Cleanup ceiling required')
    artifacts, inventories = [], {}
    for role in ('recognition', 'cleanup'):
        files = model_inventory(pack, role)
        if role == 'cleanup':
            validate_cleanup_layout({name.removeprefix('cleanup/'): value for name, value in files.items()})
        inventories[role] = summary(files)
        for relative, identity in files.items():
            artifacts.append(dict(role=role, url=base_url.rstrip('/') + '/' + quote(relative, safe='/'),
                                  relativePath=relative, **identity,
                                  license=artifact_license(relative, role, config)))
    if not any(a['relativePath'].startswith('recognition/unified/') for a in artifacts):
        raise ValueError('recognition/unified runtime files required')
    manifest.update(cleanupTokenCeiling=ceiling, artifacts=artifacts)
    return manifest, inventories


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pack', type=Path, required=True)
    parser.add_argument('--config', type=Path, default=Path('Models/production-config.json'))
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--minimum-application-version', required=True)
    parser.add_argument('--maximum-application-version', required=True)
    parser.add_argument('--cleanup-token-ceiling', required=True, type=int)
    args = parser.parse_args()
    manifest, inventories = build(args.pack, json.loads(args.config.read_text()), args.base_url,
        args.version, args.minimum_application_version, args.maximum_application_version, args.cleanup_token_ceiling)
    output = args.pack / 'manifest.json'
    with output.open('x') as file:
        file.write(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    print(json.dumps(dict(manifest=str(output), artifactHashFormat='sha256-canonical-file-inventory-v1',
                         inventories=inventories), indent=2, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        sys.exit(str(error))

"""Identity of the regular files installed and loaded from a Model Pack."""
import hashlib
import json
from pathlib import Path


def digest(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def inventory(directory):
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('regular model directory required')
    result = {}
    for path in sorted(directory.rglob('*')):
        if path.is_symlink():
            raise ValueError('model files must not contain symbolic links')
        if path.is_dir():
            continue
        if not path.is_file() or path.stat().st_size <= 0:
            raise ValueError('nonempty regular model files required')
        result[path.relative_to(directory).as_posix()] = dict(byteSize=path.stat().st_size, sha256=digest(path))
    if not result:
        raise ValueError('empty model directory')
    return result


def summary(files):
    canonical = json.dumps(files, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()
    return dict(byteSize=sum(value['byteSize'] for value in files.values()),
                sha256=hashlib.sha256(canonical).hexdigest())


def validate_cleanup_layout(files):
    """A flat fused model, or separate base/ and adapters/ trees for unfused LoRA."""
    nested = any(name.startswith(('base/', 'adapters/')) for name in files)
    prefix = 'base/' if nested else ''
    required = {prefix + name for name in ('config.json', 'tokenizer.json', 'tokenizer_config.json')}
    if nested:
        required |= {'adapters/adapter_config.json', 'adapters/adapters.safetensors'}
    if not required <= files.keys() or not any(
            name.startswith(prefix) and name.endswith('.safetensors')
            and '/' not in name.removeprefix(prefix) for name in files):
        raise ValueError('incomplete Cleanup base or adapter layout')


def model_inventory(pack, role):
    if role not in ('recognition', 'cleanup'):
        raise ValueError('unknown model role')
    directories = ('recognition', 'vad') if role == 'recognition' else ('cleanup',)
    result = {}
    for name in directories:
        directory = Path(pack) / name
        if name == 'vad' and not directory.exists() and not directory.is_symlink():
            continue
        result.update({f'{name}/{path}': value for path, value in inventory(directory).items()})
    return result

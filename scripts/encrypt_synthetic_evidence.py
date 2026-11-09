#!/usr/bin/env python3
"""Encrypt an allowlisted synthetic UI packet; never print plaintext evidence.

Hybrid: cryptography RSA-3072 OAEP SHA-256 wraps a random AES-256-GCM key.
The canonical header is authenticated associated data. Decryptors MUST use
AESGCM.decrypt (tag verification) before parsing or extracting.
Only this runner's fixed synthetic capture directory is read. No glob archive.
"""
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import secrets
import stat
import struct
import subprocess
import sys
import zipfile


NAMES = (
    'keyboard-material-macOS.png', 'keyboard-material-windows.png',
    'keyboard-mornye-macOS.png', 'keyboard-mornye-windows.png',
    'band-160x320.png', 'reference-160x320.png',
    'difference-160x320.png', 'difference-160x320.json',
)
PUBLIC_KEY_SHA256 = '5baa4d426e68a71bb74d86d1a72b4d052f98d0472f8ec5598ce9ad61d146acc1'
MAX_FILE = 1024 * 1024
MAX_TOTAL = 2 * 1024 * 1024
MAX_ENVELOPE = 3 * 1024 * 1024


def command(args, data=None):
    result = subprocess.run(args, input=data, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError('Encryption or source-binding command failed')
    return result.stdout


def main():
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding, rsa
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    runner = Path(os.environ['RUNNER_TEMP'])
    root = runner / 'mornye-synthetic-evidence'
    if root.absolute() != root.resolve() or runner.absolute() != runner.resolve():
        raise ValueError('Evidence path contains symlink')
    mode = root.lstat()
    if not stat.S_ISDIR(mode.st_mode) or mode.st_uid != os.getuid():
        raise ValueError('Evidence directory rejected')
    if set(os.listdir(root)) - set(NAMES):
        raise ValueError('Unexpected evidence entry')
    public = Path('patches/synthetic-evidence-public.pem').read_bytes()
    if hashlib.sha256(public).hexdigest() != PUBLIC_KEY_SHA256:
        raise ValueError('Evidence public-key binding mismatch')
    sha = command(['git', 'rev-parse', 'HEAD']).decode().strip()
    tree = command(['git', 'rev-parse', 'HEAD^{tree}']).decode().strip()
    if sha != os.environ['GITHUB_SHA']:
        raise ValueError('Checked-out source does not match event SHA')
    members, missing, total = {}, [], 0
    # O_NOFOLLOW + fstat reject links, devices, hardlinks, changed identities.
    for name in NAMES:
        path = root / name
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except FileNotFoundError:
            missing.append(name)
            continue
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                    or info.st_uid != os.getuid() or info.st_size > MAX_FILE):
                raise ValueError('Evidence file type, owner, link or size rejected')
            data = stream.read(MAX_FILE + 1)
            if len(data) > MAX_FILE:
                raise ValueError('Evidence file exceeded cap')
        if name.endswith('.png'):
            expected = (1200, 3000) if name.startswith('keyboard-') else (160, 320)
            if (len(data) < 33 or not data.startswith(b'\x89PNG\r\n\x1a\n')
                    or data[12:16] != b'IHDR'
                    or struct.unpack('>II', data[16:24]) != expected):
                raise ValueError('Evidence PNG signature or dimensions rejected')
        if name.endswith('.json'):
            measurement = json.loads(data)
            fields = {'width', 'height', 'maximum_channel_difference',
                      'channels_above_one', 'first_128_positions',
                      'difference_png_rgb_scale'}
            if (not isinstance(measurement, dict) or set(measurement) != fields
                    or measurement['width'] != 160 or measurement['height'] != 320
                    or measurement['difference_png_rgb_scale'] != 64
                    or type(measurement['maximum_channel_difference']) is not int
                    or not 0 <= measurement['maximum_channel_difference'] <= 255
                    or type(measurement['channels_above_one']) is not int
                    or not 0 <= measurement['channels_above_one'] <= 160 * 320 * 4
                    or not isinstance(measurement['first_128_positions'], list)
                    or len(measurement['first_128_positions']) > 128):
                raise ValueError('Evidence measurement format rejected')
            limits = {'x': 159, 'y': 319, 'channel': 3, 'band': 255,
                      'reference': 255, 'difference': 255}
            for position in measurement['first_128_positions']:
                if (not isinstance(position, dict) or set(position) != set(limits)
                        or any(type(position[k]) is not int
                               or not 0 <= position[k] <= limit
                               for k, limit in limits.items())):
                    raise ValueError('Evidence measurement position rejected')
        total += len(data)
        if total > MAX_TOTAL:
            raise ValueError('Evidence packet exceeded cap')
        members[name] = data
    if not members:
        raise ValueError('No synthetic captures available')
    manifest = {
        'checkout_sha': sha, 'checkout_tree': tree,
        'run_id': os.environ['GITHUB_RUN_ID'],
        'run_attempt': os.environ['GITHUB_RUN_ATTEMPT'],
        'missing': missing,
        'files': {name: {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                  for name, data in members.items()},
    }
    packet = io.BytesIO()
    with zipfile.ZipFile(packet, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('manifest.json', json.dumps(manifest, sort_keys=True))
        for name, data in members.items():
            archive.writestr(name, data)
    public_key = serialization.load_pem_public_key(public)
    if not isinstance(public_key, rsa.RSAPublicKey) or public_key.key_size != 3072:
        raise ValueError('Evidence encryption key rejected')
    key = AESGCM.generate_key(bit_length=256)
    nonce = secrets.token_bytes(12)
    wrapped = public_key.encrypt(key, padding.OAEP(
        mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
    b64 = lambda value: base64.b64encode(value).decode('ascii')
    header = json.dumps({
        'version': 1, 'scheme': 'RSA-OAEP-SHA256+AES-256-GCM',
        'key_sha256': PUBLIC_KEY_SHA256, 'wrapped_key': b64(wrapped),
        'nonce': b64(nonce), 'checkout_sha': sha, 'checkout_tree': tree,
    }, sort_keys=True, separators=(',', ':')).encode()
    ciphertext = AESGCM(key).encrypt(nonce, packet.getvalue(), header)
    envelope = json.dumps({'header': b64(header), 'ciphertext': b64(ciphertext)},
                          separators=(',', ':')).encode()
    encoded = b64(envelope)
    if len(encoded) > MAX_ENVELOPE:
        raise ValueError('Encrypted log payload exceeded cap')
    # Emit only after successful authenticated encryption and every validation above.
    digest = hashlib.sha256(envelope).hexdigest()
    print(f'MORNYE_SYNTHETIC_BEGIN sha256={digest} bytes={len(envelope)}')
    for index in range(0, len(encoded), 3000):
        print(f'MORNYE_SYNTHETIC_CHUNK {index // 3000:04d} {encoded[index:index+3000]}')
    print('MORNYE_SYNTHETIC_END')
    if missing:
        print('Synthetic evidence incomplete; encrypted manifest lists missing captures.')
        return 1
    return 0


if __name__ == '__main__':
    try:
        status = main()
    except Exception:
        # Never dump subprocess output, key material, pixels or measurements.
        print('Synthetic evidence encryption failed closed.', file=sys.stderr)
        status = 1
    finally:
        # Delete only explicit regular allowlisted files, never traverse links.
        root = Path(os.environ.get('RUNNER_TEMP', '/nonexistent')) / 'mornye-synthetic-evidence'
        if root.absolute() == root.resolve() and root.is_dir() and not root.is_symlink():
            for name in NAMES:
                target = root / name
                try:
                    if stat.S_ISREG(target.lstat().st_mode):
                        target.unlink()
                except FileNotFoundError:
                    pass
    sys.exit(status)

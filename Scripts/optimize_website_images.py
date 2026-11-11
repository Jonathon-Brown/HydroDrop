#!/usr/bin/env python3
"""Create WebP delivery copies without changing the native source artwork (requires cwebp)."""
from pathlib import Path
import subprocess

repo = Path(__file__).resolve().parents[1]
site = repo / 'docs'
original = compressed = 0
sources = list((site / 'assets').rglob('*.png')) + list((site / 'screenshots').glob('*.jpg'))
for source in sources:
    output = source.with_suffix('.webp')
    # Lossless mascot exports retain the native face, gradients and transparent edges exactly.
    options = ['-lossless', '-z', '9'] if source.parent.name == 'mascots' else ['-q', '85', '-m', '6']
    if source.parent.name == 'icons':
        options += ['-resize', '192', '192']
    subprocess.run(['cwebp', '-quiet', *options, str(source), '-o', str(output)], check=True)
    original += source.stat().st_size
    compressed += output.stat().st_size
print(f'Delivery assets: {original:,} → {compressed:,} bytes ({100 * (1 - compressed / original):.1f}% smaller).')

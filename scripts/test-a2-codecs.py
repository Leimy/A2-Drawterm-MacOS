#!/usr/bin/env python3
"""Check native radio codecs, live frame synchronization and logical stream changes."""
import array
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import wave

repo = Path(__file__).resolve().parent.parent
bundle = Path(sys.argv[1]).resolve()
compiler = Path(os.environ.get('A2_COMPILER_LIBRARY', repo / 'build/native-compiler')).resolve()
with tempfile.TemporaryDirectory(prefix='a2-codecs-') as temporary:
    directory = Path(temporary)
    env = dict(os.environ, AOSCONFIG='Color 0 StackSize 8192',
               AOSPATH=f'{bundle}:{compiler}:{bundle / "data"}',
               OBERON_CORE=str(compiler / 'DarwinAosCompilerAa'))
    vorbis = (bundle / 'data/RadioGlobeTest.ogg').read_bytes()
    chained = directory / 'chained.ogg'
    chained.write_bytes(vorbis + vorbis)
    cases = [(str(bundle / 'data' / f'RadioGlobeTest{suffix}'), suffix, 1)
             for suffix in ('.mp3', '.aac', '-HE.aac', '-Mono.aac', '.ogg', '.flac', '.opus', '-FLAC.ogg')]
    cases.append((str(chained), 'chained Vorbis', 2))
    ogg_flac = (bundle / 'data/RadioGlobeTest-FLAC.ogg').read_bytes()
    ogg_flac_chain = directory / 'chained-flac.ogg'
    ogg_flac_chain.write_bytes(ogg_flac * 2)
    cases.append((str(ogg_flac_chain), 'chained Ogg FLAC', 2))
    opus = (bundle / 'data/RadioGlobeTest.opus').read_bytes()
    opus_chain = directory / 'chained.opus'
    opus_chain.write_bytes(opus * 2)
    cases.append((str(opus_chain), 'chained Opus', 2))
    # Icecast sends cached BOS/header pages, then joins the live page sequence.
    def ogg_crc(page):
        page[22:26] = bytes(4)
        crc = 0
        for byte in page:
            crc ^= byte << 24
            for _ in range(8):
                crc = ((crc << 1) ^ (0x04c11db7 if crc & 0x80000000 else 0)) & 0xffffffff
        page[22:26] = crc.to_bytes(4, 'little')
    live = bytearray(opus)
    offset = 0
    while offset < len(live):
        segments = live[offset + 26]
        size = 27 + segments + sum(live[offset + 27:offset + 27 + segments])
        page = live[offset:offset + size]
        sequence = int.from_bytes(page[18:22], 'little')
        if sequence >= 2:
            page[18:22] = (sequence + 900).to_bytes(4, 'little')
            granule = int.from_bytes(page[6:14], 'little')
            page[6:14] = (granule + 48000000).to_bytes(8, 'little')
            ogg_crc(page)
            live[offset:offset + size] = page
        offset += size
    # Split an Opus packet across pages, exercising Ogg's continuation flag.
    continued = bytearray()
    offset = 0
    shifted = False
    while offset < len(opus):
        segments = opus[offset + 26]
        size = 27 + segments + sum(opus[offset + 27:offset + 27 + segments])
        page = bytearray(opus[offset:offset + size])
        sequence = int.from_bytes(page[18:22], 'little')
        if sequence >= 2 and not shifted and page[27] == 255:
            first = page[:27] + bytes([255]) + page[27 + segments:27 + segments + 255]
            first[26] = 1
            first[6:14] = bytes([255]) * 8
            ogg_crc(first)
            continued.extend(first)
            rest = page[:27] + page[28:27 + segments] + page[27 + segments + 255:]
            rest[5] |= 1
            rest[26] -= 1
            rest[18:22] = (sequence + 1).to_bytes(4, 'little')
            ogg_crc(rest)
            continued.extend(rest)
            shifted = True
        else:
            if shifted:
                page[18:22] = (sequence + 1).to_bytes(4, 'little')
                ogg_crc(page)
            continued.extend(page)
        offset += size
    assert shifted, 'Fixture must contain an Opus packet longer than 255 bytes'
    continued_path = directory / 'continued.opus'
    continued_path.write_bytes(continued)
    cases.append((str(continued_path), 'Opus packet continued across pages', 1))
    live_path = directory / 'live.opus'
    live_path.write_bytes(live)
    cases.append((str(live_path), 'live Opus sequence/granule offset', 1))
    mp3 = (bundle / 'data/RadioGlobeTest.mp3').read_bytes()
    prefixed = directory / 'prefixed.mp3'
    # Deliberate false sync word, random prefix and intact tone audio.
    prefixed.write_bytes(b'\xff\xfb\x90\x00' + bytes(range(128)) + mp3)
    cases.append((str(prefixed), 'MP3 arbitrary live prefix', 1))
    for source, label, repeats in cases:
        target = directory / 'decoded.wav'
        result = subprocess.run([str(bundle / 'OberonLoader'), 'do',
                                 f'RadioGlobeAudio.DecodeNative {source} {target}'],
                                cwd=temporary, env=env, capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        assert result.returncode == 0 and 'Audio decoded bytes=' in output, output
        assert not any(s in output for s in ('Trap ', 'native signal', 'codec error')), output
        with wave.open(str(target)) as f:
            assert (f.getnchannels(), f.getframerate(), f.getsampwidth()) == (2, 44100, 2)
            pcm = array.array('h', f.readframes(f.getnframes()))
            if sys.byteorder != 'little': pcm.byteswap()
            if label == '-Mono.aac':
                assert pcm[::2] == pcm[1::2], 'Mono channel mapping differs between output channels'
            samples = pcm[::2]
            assert 88200 * repeats <= len(samples) <= 96000 * repeats, (label, len(samples))
            assert max(map(abs, samples)) < 7000, label
            if label in ('.flac', '.opus', 'live Opus sequence/granule offset', 'chained Opus', 'Opus packet continued across pages', '-FLAC.ogg', 'chained Ogg FLAC'):
                assert len(samples) == 88200 * repeats, (label, len(samples))
            for repeat in range(repeats):
                for start, hz, reject in ((0.3, 440, 660), (1.3, 660, 440)):
                    offset = int((repeat * 2 + start) * 44100)
                    segment = samples[offset:offset + 4410]
                    def amplitude(frequency):
                        return abs(sum(x * complex(math.cos(2 * math.pi * frequency * i / 44100),
                                                   math.sin(2 * math.pi * frequency * i / 44100))
                                       for i, x in enumerate(segment))) / len(segment)
                    assert amplitude(hz) > 2000 and amplitude(reject) < 100, label
        print(f'CODEC PASS {label}: duration, amplitude and pitch')

    broken = bytearray(opus)
    broken[35] ^= 1  # Invalid BOS page checksum.
    bad = directory / 'bad.opus'
    bad.write_bytes(broken)
    result = subprocess.run([str(bundle / 'OberonLoader'), 'do',
                             f'RadioGlobeAudio.DecodeNative {bad} {directory / "bad.wav"}'],
                            cwd=temporary, env=env, capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    assert 'Native audio decode failed' in output, output
    assert not any(s in output for s in ('Trap ', 'native signal')), output
    assert not (directory / 'bad.wav').exists()
    print('CODEC PASS invalid Opus page rejected without registering output')

    # A one-frame native FLAC stream needs no following sync header at EOF.
    flac = (bundle / 'data/RadioGlobeTest.flac').read_bytes()
    offset = 4
    while True:
        last = flac[offset] & 128
        size = int.from_bytes(flac[offset + 1:offset + 4], 'big')
        offset += 4 + size
        if last: break
    crc = 0
    end = offset
    while end < len(flac):
        byte = flac[end]
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ (0x8005 if crc & 32768 else 0)) & 65535
        end += 1
        if end - offset >= 8 and crc == 0 and flac[end:end + 2] == b'\xff\xf8':
            break
    assert end < len(flac)
    header = bytearray(flac[:42])
    header[4] |= 128
    samples = int.from_bytes(header[10:12], 'big')
    packed = int.from_bytes(header[18:26], 'big')
    header[18:26] = ((packed & ~((1 << 36) - 1)) | samples).to_bytes(8, 'big')
    header[26:42] = bytes(16)  # Unknown MD5, permitted by STREAMINFO.
    single = directory / 'single.flac'
    single.write_bytes(header + flac[offset:end])
    result = subprocess.run([str(bundle / 'OberonLoader'), 'do',
                             f'RadioGlobeAudio.DecodeNative {single} {directory / "single.wav"}'],
                            cwd=temporary, env=env, capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    assert 'Audio decoded bytes=' in output and 'Trap ' not in output, output
    with wave.open(str(directory / 'single.wav')) as f:
        assert f.getnframes() == samples, (f.getnframes(), samples)
    print('CODEC PASS single-frame FLAC EOF')
    corrupt = bytearray(single.read_bytes())
    corrupt[-1] ^= 1
    single.write_bytes(corrupt)
    result = subprocess.run([str(bundle / 'OberonLoader'), 'do',
                             f'RadioGlobeAudio.DecodeNative {single} {directory / "corrupt.wav"}'],
                            cwd=temporary, env=env, capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    assert 'Native audio decode failed' in output and 'Trap ' not in output, output
    assert not (directory / 'corrupt.wav').exists()
    print('CODEC PASS damaged FLAC frame rejected')

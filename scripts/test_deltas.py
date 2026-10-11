import base64
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import publish
from test_publish import feed


class DeltaTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.meta = dict(build=2, arch='arm64', feed=publish.CDN + '/mac/arm64/appcast.xml', public_key='key')
        self.sig = base64.b64encode(bytes(64)).decode()
        self.name = 'Tilr2-1.delta'
        self.delta = self.root / self.name
        self.delta.write_bytes(b'patch')
        root = ET.fromstring(feed())
        deltas = ET.SubElement(root.find('channel/item'), f'{{{publish.SPARKLE}}}deltas')
        ET.SubElement(deltas, 'enclosure', {'url': publish.CDN + '/mac/arm64/' + self.name,
            'length': '5', f'{{{publish.SPARKLE}}}deltaFrom': '1', f'{{{publish.SPARKLE}}}edSignature': self.sig})
        self.data = ET.tostring(root)

    def test_valid_delta_and_reject_mixed_track_source_or_tampering(self):
        with patch.object(publish, 'run') as run:
            entries = publish.validate_deltas(self.data, self.meta, self.root, self.root, [1])
            self.assertEqual(entries[0]['source'], 1)
            self.assertIn('--verify', run.call_args.args)
            for old, new in [(b'/arm64/', b'/x86_64/'), (b'deltaFrom="1"', b'deltaFrom="2"'),
                             (b'length="5"', b'length="6"'), (self.name.encode(), b'../escape.delta')]:
                with self.assertRaises((ValueError, FileNotFoundError)):
                    publish.validate_deltas(self.data.replace(old, new), self.meta, self.root, self.root, [1])
            with self.assertRaises(ValueError):
                publish.validate_deltas(self.data, self.meta, self.root, self.root, [])

    def test_delta_download_must_match_before_feed_can_be_uploaded(self):
        events = []
        objects = {}
        def fetch(url, target):
            value = objects.get(url.split('?')[0])
            if value is None:
                return False
            target.write_bytes(value)
            events.append(('verified', url))
            return True
        def put(path, key, *args):
            objects[publish.CDN + '/' + key] = path.read_bytes()
            events.append(('put', key))
        with patch.object(publish, 'fetch', side_effect=fetch), patch.object(publish, 'put', side_effect=put):
            publish.upload_deltas(self.meta, self.data, self.root)
            publish.upload_deltas(self.meta, self.data, self.root)
        self.assertEqual(len([x for x in events if x[0] == 'put']), 1)
        self.assertTrue(events[-1][0] == 'verified')
        with patch.object(publish, 'fetch', return_value=False), patch.object(publish, 'put'):
            with self.assertRaisesRegex(ValueError, 'feed was NOT updated'):
                publish.upload_deltas(self.meta, self.data, self.root)

    def test_failed_delta_download_never_publishes_feed_after_full_dmg(self):
        dmg = self.root / 'Tilr-0.1.1-2-arm64.dmg'
        dmg.write_bytes(b'dmg')
        meta = dict(self.meta, sha256=publish.digest(dmg))
        candidate = self.root / 'appcast.xml'
        candidate.write_bytes(self.data)
        def fetch(url, target):
            if publish.urlsplit(url).path.endswith('.dmg'):
                target.write_bytes(b'dmg')
                return True
            return False
        with patch.object(publish, 'fetch', side_effect=fetch), patch.object(publish, 'put') as put:
            with self.assertRaisesRegex(ValueError, 'feed was NOT updated'):
                publish.upload_verified_assets(meta, dmg, candidate, self.root)
        self.assertFalse(any(call.args[1].endswith('appcast.xml') for call in put.call_args_list))

    def test_missing_remote_delta_blocks_resume(self):
        with patch.object(publish, 'fetch', return_value=False):
            with self.assertRaisesRegex(ValueError, 'Published delta'):
                publish.verify_remote_deltas(self.data, self.meta, self.root, self.root)

    def test_history_only_same_arch_channel_and_authenticated_published_archive(self):
        for arch, channel, build in [('arm64','stable',1), ('x86_64','stable',1), ('arm64','beta',1)]:
            directory = self.root / f'{arch}-{channel}'
            directory.mkdir()
            name = 'Tilr-0.1.1-1-arm64.dmg'
            archive = directory / name
            archive.write_bytes(b'old')
            meta = dict(build=build, arch=arch, version='0.1.1', preview=False, public_key='key', dmg=name,
                        sha256=publish.digest(archive), feed=publish.CDN + ('/mac/' if channel == 'stable' else '/mac/beta/') + arch + '/appcast.xml')
            (directory / 'release.json').write_text(json.dumps(meta))
        old = feed(build=1, url=publish.CDN + '/mac/arm64/Tilr-0.1.1-1-arm64.dmg')
        stage = self.root / 'stage'
        stage.mkdir()
        with patch.object(publish, 'run') as run:
            self.assertEqual(publish.stage_delta_history(self.meta, old, stage, self.root, 2, self.root), [1])
            self.assertEqual(run.call_count, 1)
            self.assertEqual(publish.stage_delta_history(self.meta, None, stage, self.root, 2, self.root), [])
            self.assertEqual(publish.stage_delta_history(self.meta, old, stage, self.root, 0, self.root), [])
        (self.root / 'arm64-stable/Tilr-0.1.1-1-arm64.dmg').write_bytes(b'bad')
        with self.assertRaisesRegex(ValueError, 'Historical DMG checksum'):
            publish.stage_delta_history(self.meta, old, stage, self.root, 2, self.root)

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

report = module('dialogue-salience-report')
gates = module('verify-salience-gates')
auditions = module('verification-auditions')
media = module('prepare-verification-media')
matrix = module('verify-matrix-integrity')
app = module('verify-app-playback')


class IntegrityTests(unittest.TestCase):
    def corpus(self):
        films = [dict(id=str(i), file=str(i)+'.mp4', duration=600, sha256='hash', url='source') for i in range(12)]
        rows = [dict(film=f['id'], chunk=c, offset=c*30, decode='success', decodedFrames=1440000,
                     sampleRate=48000, speechWindows=1, renderOutcomes={m: dict(planned=3, rendered=3, audible=3) for m in ('T','A')}, model='apple', transcriptOutcome='result', transcribed=True, transcriptWords=10, transcriptLocale='en-US', transcriptModelVersion='apple-v1')
                for f in films for c in range(8)]
        return dict(corpus=dict(films=films, chunks=8, bpm=72, seed=1, modes=['T', 'A']),
                    windowOutcomes=rows, attempts=[dict(film=w['film'], chunk=w['chunk'], decode='attempted') for w in rows])

    def test_partial_corpus_and_duplicate_window_cannot_qualify(self):
        before, after = self.corpus(), self.corpus()
        self.assertTrue(gates.evaluate(before, after)['pairedCorpusComplete']['passed'])
        after['windowOutcomes'][-1] = after['windowOutcomes'][0]
        self.assertFalse(gates.evaluate(before, after)['pairedCorpusComplete']['passed'])
        self.assertFalse(gates.evaluate(before, after)['transcriptEvidence']['passed'])

    def test_missing_render_in_one_window_cannot_hide_in_corpus_totals(self):
        before, after = self.corpus(), self.corpus()
        self.assertTrue(gates.evaluate(before, after)['windowRenderCoverage']['passed'])
        after['windowOutcomes'][1]['renderOutcomes']['T']['rendered'] = 2
        self.assertFalse(gates.evaluate(before, after)['windowRenderCoverage']['passed'])

    def test_one_transcript_cannot_qualify_and_silence_is_separate(self):
        before, after = self.corpus(), self.corpus()
        after['windowOutcomes'][3]['transcribed'] = False
        self.assertFalse(gates.evaluate(before, after)['transcriptEvidence']['passed'])
        after['windowOutcomes'][3]['speechWindows'] = 0
        self.assertTrue(gates.evaluate(before, after)['transcriptEvidence']['passed'])

    def test_fresh_absolute_counts_are_not_historical_certification(self):
        after = dict(salientWords=dict(inWindows=159, inRankedLine=159, inChosenLine=159))
        self.assertFalse(gates.evaluate({}, after)['T.stage2.inRankedLine']['passed'])
        after['historicalMatch'] = dict(verified=True, provenance='authenticated original corpus identity record')
        self.assertTrue(gates.evaluate({}, after)['T.stage2.inRankedLine']['passed'])

    def test_render_and_detection_missing_fail_even_with_good_timing(self):
        coverage = dict(planned=10, inventoryPlanned=10, rendered=10, audible=10, onsetEligible=8, onsetDetected=8)
        after = {'T': {'renderCoverage': coverage}}
        self.assertTrue(gates.evaluate({}, after)['T.after.renderCoverage']['passed'])
        coverage['rendered'] = 9
        self.assertFalse(gates.evaluate({}, after)['T.after.renderCoverage']['passed'])
        coverage['rendered'] = 10
        coverage['onsetDetected'] = 7
        self.assertFalse(gates.evaluate({}, after)['T.after.renderCoverage']['passed'])

    def test_reheard_exact_tokens_modes_content_and_control_denominators(self):
        hit = dict(mode='T', kind='piece', gateEnd='natural', renderAudible=True, snippet='a',
                   words=[dict(t='trip', cov=1, fn=False)], reheard='tripping')
        self.assertEqual(report.reheard_table([hit])['T/wholeContent/piece/natural']['mainWord'], 0)
        hit['reheard'] = 'a TRIP!'
        acoustic = dict(hit, mode='A')
        control = dict(hit, control=True)
        rows = report.reheard_table([hit, acoustic, control])
        self.assertEqual(len(rows), 3)
        self.assertTrue(gates.evaluate({}, {'reheard': rows})['T.reheardMainContentWord']['passed'])
        del rows['T/wholeContent/piece/natural']
        self.assertFalse(gates.evaluate({}, {'reheard': rows})['T.reheardMainContentWord']['passed'])

    def figure(self):
        return dict(mode='T', kind='letter', complete=True, parentText='DMT', parent=1,
                    spellUnits=[2,3,4], transportStart=0, seconds=6,
                    events=[dict(id=i, step=s, start=s*.1, end=s*.1+.1) for i,s in [(2,0),(3,1),(4,2),(1,4)]])

    def test_audition_requires_complete_order_grid_containment_and_semantics(self):
        row = self.figure()
        self.assertTrue(auditions.qualifies(row))
        row['events'][1]['id'] = 4
        self.assertFalse(auditions.qualifies(row))
        row = self.figure(); row['events'][-1]['end'] = 7
        self.assertFalse(auditions.qualifies(row))
        row = self.figure(); row['kind'] = 'acoustic'
        self.assertFalse(auditions.qualifies(row))
        row = self.figure(); row.update(kind='syllable', parentText='psilocybin', semanticClass='drug')
        self.assertTrue(auditions.qualifies(row))
        row['semanticClass'] = 'unclassified'
        self.assertFalse(auditions.qualifies(row))

    def test_cache_fallback_derivative_mismatch_and_corruption_refetch(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'film.mp4'; path.write_bytes(b'second derivative')
            sidecar = path.with_suffix('.provenance.json')
            file = dict(name='second.mp4')
            sidecar.write_text(json.dumps(dict(id='film', url='second-url', archiveFile=file,
                metadataSHA256='metadata', sha256=media.digest(path))))
            self.assertTrue(media.cached_matches(path, sidecar, 'film', file, 'second-url', 'metadata'))
            self.assertFalse(media.cached_matches(path, sidecar, 'film', dict(name='first.mp4'), 'first-url', 'metadata'))
            path.write_bytes(b'corrupt')
            self.assertFalse(media.cached_matches(path, sidecar, 'film', file, 'second-url', 'metadata'))

    def test_decode_coverage_is_actual_samples_not_metadata(self):
        with patch.object(media.subprocess, 'check_output', return_value=bytes(30*48000*4)) as decode:
            rows = media.decoded_windows(Path('film.mp4'), 600)
            self.assertEqual(len(rows), 8)
            self.assertEqual(decode.call_count, 8)
        with patch.object(media.subprocess, 'check_output', return_value=b''):
            with self.assertRaises(RuntimeError): media.decoded_windows(Path('film.mp4'), 600)

    def test_matrix_requires_all_cases_and_real_transcription(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for case in matrix.REQUIRED:
                target = root/case; (target/'report').mkdir(parents=True)
                (target/'manifest.json').write_text(json.dumps(dict(gitRevision='candidate', dialogueTranscripts=[dict(status='ready', words=3, transcriptUsed=True)])))
                (target/'report/mix-report.json').write_text(json.dumps(dict(criteria=[dict(id='C-D1', level='fail', status='pass')])))
            self.assertTrue(matrix.inventory(root, revision='candidate')['complete'])
            self.assertFalse(matrix.inventory(root, revision='wrong-revision')['complete'])
            (root/'transcribe/skipped.txt').write_text('unavailable')
            self.assertFalse(matrix.inventory(root, revision='candidate')['complete'])
            (root/'transcribe/skipped.txt').unlink()
            (root/'transcribe/manifest.json').write_text(json.dumps(dict(dialogueTranscripts=[dict(status='ready', words=0, transcriptUsed=False)])))
            self.assertFalse(matrix.inventory(root, revision='candidate')['complete'])

    def test_app_survival_alone_is_no_playback_evidence(self):
        self.assertFalse(app.evidence('process survived 200s')['hook'])
        evidence = app.evidence('Lo-Fi dialogue hook\n📼 piece #2 sound=true\nsalient-pick id=f')
        self.assertTrue(evidence['hook'] and evidence['footage'] and evidence['salientPick'])

class SwiftRunnerIntegrityTests(unittest.TestCase):
    def test_zero_or_omitted_method_cannot_qualify_suite(self):
        runner = module('verify-swift-test-coverage')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'Example.swift').write_text('struct Example { @Test func one() {}\n@Test(arguments: [1,2]) func two(_ value: Int) {} }')
            text='✔ Suite Example passed after 1 second.\n✔ Test one() passed after 0.1 seconds.\n'
            self.assertFalse(runner.coverage('', root, ['Example'])['passed'])
            self.assertFalse(runner.coverage(text, root, ['Example'])['passed'])
            text+='✘ Test two(_:) with 2 test cases failed after 0.2 seconds with 1 issue.\n'
            self.assertTrue(runner.coverage(text, root, ['Example'])['passed'])

    def test_shared_file_suite_scope_ignores_siblings_nested_types_and_literals(self):
        runner = module('verify-swift-test-coverage')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'Shared.swift').write_text('''// struct Fake { @Test func fake() {} }
struct First {
    let ordinary = "} @Test func fake() {"
    let raw = #"} \" @Test func rawFake() {}"#
    let multiline = """ } @Test func multilineFake() {} """
    /* } /* nested { */ @Test func commentFake() {} */
    @Test func one() { let closure = { 1 }; _ = closure() }
    struct Nested { @Test func nested() {} }
}
struct Sibling { @Test func two() {} }
extension First { @Test func three() {} }
''')
            self.assertEqual(runner.declared_tests(root)['First'], {'one', 'three'})
            self.assertEqual(runner.declared_tests(root)['Sibling'], {'two'})
            text = '✔ Suite First passed after 1 second.\n✔ Test one() passed after 0.1 seconds.\n'
            result = runner.coverage(text, root, ['First'])
            self.assertEqual(result['suites']['First']['missing'], ['three'])
            self.assertFalse(result['passed'])
            text += '✔ Test three() passed after 0.1 seconds.\n'
            self.assertTrue(runner.coverage(text, root, ['First'])['passed'])
            self.assertFalse(runner.coverage(text, root, ['Sibling'])['passed'])
            self.assertFalse(runner.coverage(text, root, ['Absent'])['passed'])

    def test_exact_historical_adapters_have_single_window_loop_and_compiler_expansion(self):
        import subprocess
        import sys
        import shutil
        root_repo=Path(__file__).resolve().parent.parent
        baseline='47a01fe267a3972241ed6918d031fffe55f26ed2'
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            files=['LiminalTests/DialogueSalienceProbeTests.swift','LiminalTests/DialogueHookMetrics.swift','Liminal/Audio/Lofi/LofiBassVoice.swift']
            for name in files:
                target=root/name; target.parent.mkdir(parents=True,exist_ok=True)
                history = root_repo.parent/'baseline' if (root_repo.parent/'baseline/.git').exists() else root_repo
                target.write_bytes(subprocess.check_output(['git','show',baseline+':'+name],cwd=history))
            subprocess.run(['git','apply',str(root_repo/'scripts/baseline-probe-measurement.patch')],cwd=root,check=True)
            subprocess.run([sys.executable,str(root_repo/'scripts/prepare-baseline-compiler.py'),str(root)],check=True)
            probe=(root/files[0]).read_text()
            self.assertEqual(probe.count('for (chunk, offset) in offsets.enumerated()'),1)
            self.assertEqual(probe.count('let offsets ='),1)
            self.assertEqual(probe.count('"decode": "boundarySkip"'),1)
            metrics=(root/files[1]).read_text()
            self.assertIn('m.fragmentsPer4 = Double(fragmentTotal) / 4',metrics)
            # Check the loop expansion equals the original arithmetic over varied group inputs.
            for n in range(15):
                bars=[[((i+j)*n)%7 for j in range(i%4)] for i in range(16)]
                original=sum(len(set(sum(bars[4*g:4*g+4],[]))) for g in range(4))/4
                total=0
                for g in range(4):
                    fragments=set()
                    for b in range(4*g,4*g+4): fragments.update(bars[b])
                    total+=len(fragments)
                self.assertEqual(total/4,original)

    def test_capture_signing_override_is_opt_in_and_preserves_default(self):
        import ast
        import os
        source=Path(__file__).with_name('check-lofi.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
        tree=ast.parse(source)
        # Execute only command construction with fake subprocess; never start captures.
        call=next(n for n in ast.walk(tree) if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='xcode' for t in n.targets))
        parent=next(n for n in ast.walk(tree) if isinstance(n,ast.With) and call in n.body)
        statements=parent.body[:parent.body.index(call)+1]
        for value, expected in [(None,False),('NO',True)]:
            commands=[]
            class Process:
                @staticmethod
                def run(command,**kwargs): commands.append(command)
                STDOUT=None
            with patch.dict(os.environ,{},clear=False):
                os.environ.pop('LIMINAL_CAPTURE_CODE_SIGNING_ALLOWED',None)
                if value: os.environ['LIMINAL_CAPTURE_CODE_SIGNING_ALLOWED']=value
                exec(compile(ast.Module(body=statements,type_ignores=[]),'capture-command','exec'),dict(os=os,subprocess=Process,log=None))
            self.assertEqual('CODE_SIGNING_ALLOWED=NO' in commands[0],expected)

"""Roundtrip and fail-closed tests for the isolated typed-operation experiment."""
import copy,json,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
import typed_operations as typed
import prepare_corpus as corpus

class TypedOperationsTests(unittest.TestCase):
    def test_canonical_targets_roundtrip(self):
        rows=[json.loads(x) for x in corpus.SOURCE.read_text().splitlines()]
        self.assertEqual(len(rows),317)
        for r in rows:
            with self.subTest(id=r['id']):
                operations=typed.encode(r['editPlan'],r['raw'])
                self.assertEqual(typed.compile_plan(operations,r['raw']),r['editPlan'])
                result=typed.resolve_output(r,json.dumps(operations)+typed.editplan.STOP_MARKER)
                self.assertEqual(result['outcome'],'cleaned',result)
                self.assertEqual(result['output'],r['clean'])

    def test_end_and_delete_use_source_positions(self):
        raw='bring the rope um'
        plan={'v':2,'e':[{'o':'delete','i':3,'c':'filler'},{'o':'end','r':'.'}]}
        self.assertEqual(typed.resolve_output({'raw':raw},json.dumps(plan)+'<END_PLAN>')['output'],'bring the rope.')
        self.assertEqual(typed.compile_plan(plan,raw)['e'][-1]['s'],4)

    def test_invalid_operations_fail_closed(self):
        invalid=[{'o':'delete','i':True,'c':'filler'}, {'o':'delete','i':-1,'c':'filler'},
                 {'o':'delete','i':2,'c':'filler'}, {'o':'delete','i':0,'c':'correction'},
                 {'o':'end','r':'arbitrary'}, {'o':'end','r':'.','i':1}, {'o':'invent'},
                 {'s':0,'e':True,'r':'','c':'filler'}]
        for operation in invalid:
            with self.subTest(operation=operation):
                result=typed.resolve_output({'raw':'um stop'},json.dumps({'v':2,'e':[operation]})+'<END_PLAN>')
                self.assertEqual(result['outcome'],'fallback')
                self.assertEqual(result['output'],'um stop')
        for generated in ['{"v":2,"v":2,"e":[]}<END_PLAN>', '{"v":true,"e":[]}<END_PLAN>', '{"v":2,"e":[]}<END_PLAN>trailing']:
            self.assertEqual(typed.resolve_output({'raw':'keep this'},generated)['outcome'],'fallback')

    def test_compilation_preserves_validator_safety(self):
        cases=[('delete this',{'v':2,'e':[{'o':'delete','i':0,'c':'filler'}]}),
               ('visit https://example.test/path',{'v':2,'e':[{'o':'end','r':'.'}]}),
               ('um stop',{'v':2,'e':[{'o':'end','r':'.'},{'o':'delete','i':0,'c':'filler'}]}),
               ('um stop',{'v':2,'e':[{'o':'end','r':'.'},{'o':'end','r':'!'}]})]
        for raw,plan in cases:
            with self.subTest(raw=raw,plan=plan):
                self.assertEqual(typed.resolve_output({'raw':raw},json.dumps(plan)+'<END_PLAN>')['outcome'],'fallback')
        reserved={'raw':'um stop','reservedEdits':[{'s':0,'e':1,'r':'','c':'correction'}]}
        plan={'v':2,'e':[{'o':'delete','i':0,'c':'filler'}]}
        self.assertEqual(typed.resolve_output(reserved,json.dumps(plan)+'<END_PLAN>')['outcome'],'fallback')

if __name__=='__main__':unittest.main()

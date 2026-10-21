"""The discriminator changes syntax, not compiled edits or validation policy."""
import json,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
import uniform_operations as uniform
import typed_operations as hybrid
import prepare_corpus as corpus

class UniformOperationsTests(unittest.TestCase):
    def test_all_targets_roundtrip(self):
        rows=[json.loads(x) for x in corpus.SOURCE.read_text().splitlines()]
        for r in rows:
            with self.subTest(id=r['id']):
                document=uniform.encode(r['editPlan'],r['raw'])
                self.assertTrue(all('o' in operation for operation in document['e']))
                self.assertEqual(uniform.compile_plan(document,r['raw']),r['editPlan'])
                result=uniform.resolve_output(r,json.dumps(document)+'<END_PLAN>')
                self.assertEqual(result['outcome'],'cleaned',result)
                self.assertEqual(result['output'],r['clean'])

    def test_explicit_edit_and_delete_work_together(self):
        r={'raw':'bring the rope um'}
        doc={'v':2,'e':[{'o':'edit','s':0,'e':1,'r':'Bring','c':'capitalization'}, {'o':'delete','i':3,'c':'filler'},{'o':'end','r':'.'}]}
        self.assertEqual(uniform.resolve_output(r,json.dumps(doc)+'<END_PLAN>')['output'],'Bring the rope.')

    def test_malformed_discriminators_and_types_rejected(self):
        edits=[{'s':0,'e':1,'r':'Bring','c':'capitalization'},
               {'o':'edit','s':0,'e':True,'r':'Bring','c':'capitalization'},
               {'o':'edit','s':0,'e':1,'r':'Bring','c':'capitalization','i':0},
               {'o':'unknown'}, {'o':'delete','i':True,'c':'filler'}, {'o':'end','r':'word'}]
        for edit in edits:
            self.assertEqual(uniform.resolve_output({'raw':'bring it'},json.dumps({'v':2,'e':[edit]})+'<END_PLAN>')['outcome'],'fallback')
        for generated in ['{"v":2,"v":2,"e":[]}<END_PLAN>', '{"v":2,"e":[]}<END_PLAN>extra']:
            self.assertEqual(uniform.resolve_output({'raw':'bring it'},generated)['outcome'],'fallback')

    def test_edit_cannot_bypass_safety(self):
        cases=[({'raw':'keep this'}, {'o':'edit','s':0,'e':1,'r':'remove','c':'punctuation'}),
               ({'raw':'um stop','reservedEdits':[{'s':0,'e':1,'r':'','c':'correction'}]}, {'o':'delete','i':0,'c':'filler'}),
               ({'raw':'visit https://example.test/a'}, {'o':'end','r':'.'}),
               ({'raw':'keep this'}, {'o':'edit','s':0,'e':1,'r':'','c':'filler'})]
        for record,operation in cases:
            self.assertEqual(uniform.resolve_output(record,json.dumps({'v':2,'e':[operation]})+'<END_PLAN>')['outcome'],'fallback')

if __name__=='__main__':unittest.main()

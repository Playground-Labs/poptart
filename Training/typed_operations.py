"""Experimental wire format only; always compiles through the existing validator.

Not imported by the application. No heuristic repair, reordering or dropped edits.
"""
import json
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Evals'))
import editplan
import prepare_corpus
from evaluate_candidate import unique_keys

SYSTEM = prepare_corpus.SYSTEM.split(' Schema:')[0] + (
 ' Experimental schema: {"v":2,"e":[operations]}. '
 'For terminal punctuation use {"o":"end","r":"."}, with r one of ., ?, !. '
 'For deleting one filler or repeated token use {"o":"delete","i":0,"c":"filler"}, '
 'where i is the token index and c is filler or repetition. '
 'For other edits use {"s":0,"e":1,"r":"text","c":"capitalization"}. '
 'Keep operations in source order.'
)


def encode(document, source):
    count=len(editplan.tokenize(source)); operations=[]
    for e in editplan.parse_plan(document):
        if e['c']=='punctuation' and e['s']==e['e']==count and e['r'] in ('.','?','!'):
            operations.append({'o':'end','r':e['r']})
        elif e['c'] in ('filler','repetition') and e['r']=='' and e['e']==e['s']+1:
            operations.append({'o':'delete','i':e['s'],'c':e['c']})
        else: operations.append(e)
    return {'v':2,'e':operations}


def compile_plan(document, source):
    if not isinstance(document,dict) or set(document)!={'v','e'} or type(document['v']) is not int or document['v']!=2:
        raise ValueError('typed plan requires exact v2 envelope')
    if not isinstance(document['e'],list) or len(document['e'])>editplan.DEFAULT_CONFIGURATION['maximumEdits']:
        raise ValueError('invalid operations list')
    count=len(editplan.tokenize(source)); edits=[]
    for operation in document['e']:
        if not isinstance(operation,dict):raise ValueError('operation must be an object')
        if 'o' not in operation:
            edits.extend(editplan.parse_plan({'v':1,'e':[operation]}))
        elif operation.get('o')=='end':
            if set(operation)!={'o','r'} or operation['r'] not in ('.','?','!'):
                raise ValueError('invalid terminal punctuation')
            edits.append({'s':count,'e':count,'r':operation['r'],'c':'punctuation'})
        elif operation.get('o')=='delete':
            if set(operation)!={'o','i','c'} or type(operation['i']) is not int or not 0<=operation['i']<count or operation['c'] not in ('filler','repetition'):
                raise ValueError('invalid single-token deletion')
            edits.append({'s':operation['i'],'e':operation['i']+1,'r':'','c':operation['c']})
        else:raise ValueError('unknown operation')
    return editplan.plan_document(edits)


def resolve_output(record, generated):
    try:
        if not generated.endswith(editplan.STOP_MARKER):raise ValueError('incomplete or trailing output')
        body=generated[:-len(editplan.STOP_MARKER)]
        if len(body.encode('utf-8'))>8192:raise ValueError('plan byte limit')
        document=json.loads(body,object_pairs_hook=unique_keys)
        compiled=compile_plan(document,record['raw'])
        edits=editplan.parse_plan(compiled)
        reserved=record.get('reservedEdits',[])
        violation=editplan.plan_violation(edits,record['raw'],record.get('vocabularyTerms',[]),reserved,record.get('targetContext',editplan.DEFAULT_TARGET_CONTEXT))
        if violation:raise ValueError(violation)
        return {'outcome':'cleaned','output':editplan.resolve(record['raw'],edits,reserved),'editPlan':compiled,'typedPlan':document,'rejection':None}
    except (ValueError,TypeError,KeyError) as error:
        return {'outcome':'fallback','output':record['raw'],'rejection':str(error)}

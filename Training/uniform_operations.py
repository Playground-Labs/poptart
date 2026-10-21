"""Isolated uniform-discriminator experiment, not an app-supported wire format."""
import json
import typed_operations as hybrid

SYSTEM = hybrid.SYSTEM.replace(
 'For other edits use {"s":0,"e":1,"r":"text","c":"capitalization"}.',
 'For other edits use {"o":"edit","s":0,"e":1,"r":"text","c":"capitalization"}.'
)


def encode(document, source):
    encoded=hybrid.encode(document,source)
    return {'v':2,'e':[e if 'o' in e else {'o':'edit',**e} for e in encoded['e']]}


def compile_plan(document, source):
    if not isinstance(document,dict) or set(document)!={'v','e'} or type(document['v']) is not int or document['v']!=2 or not isinstance(document['e'],list):
        raise ValueError('uniform plan requires exact v2 envelope')
    if len(document['e'])>hybrid.editplan.DEFAULT_CONFIGURATION['maximumEdits']:
        raise ValueError('too many operations')
    operations=[]
    for operation in document['e']:
        if not isinstance(operation,dict) or 'o' not in operation:
            raise ValueError('every operation requires a discriminator')
        if operation['o']=='edit':
            if set(operation)!={'o','s','e','r','c'}:raise ValueError('invalid edit operation keys')
            operations.append({k:operation[k] for k in ('s','e','r','c')})
        else:operations.append(operation)
    return hybrid.compile_plan({'v':2,'e':operations},source)


def resolve_output(record, generated):
    try:
        if not generated.endswith(hybrid.editplan.STOP_MARKER):raise ValueError('incomplete or trailing output')
        body=generated[:-len(hybrid.editplan.STOP_MARKER)]
        if len(body.encode('utf-8'))>8192:raise ValueError('plan byte limit')
        document=json.loads(body,object_pairs_hook=hybrid.unique_keys)
        compiled=compile_plan(document,record['raw'])
        result=hybrid.resolve_output(record,json.dumps({'v':2,'e':compiled['e']},separators=(',',':'))+hybrid.editplan.STOP_MARKER)
        result.pop('typedPlan',None)
        result['uniformPlan']=document
        return result
    except (ValueError,TypeError,KeyError) as error:
        return {'outcome':'fallback','output':record['raw'],'rejection':str(error)}

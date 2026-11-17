#!/usr/bin/env python3
"""Closed fixture-suite dispatcher and exact-run CI aggregate; no production sync."""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import unittest
ROOT = Path(__file__).resolve().parents[1]
SHARDS = ('registry-discovery', 'payload-delivery')
NAMES = ('KleinPerkins/ecosystem-orchestrator',)
IDENTITY_KEYS = ('repository','repository_id','event','revision','workflow_sha','run_id',
                 'run_attempt','ref','head_sha','base_sha','workflow_ref','workflow')
MAX_OUTPUT = 8 * 1024 * 1024
BASELINE = (
    'tests/test_registry_cli.sh', 'tests/test_plugin_discovery.sh',
    'tests/test_google_kit_payload.sh', 'tests/test_tool_descriptor_payload.sh',
    'tests/test_tool_snapshot_payload.sh', 'tests/test_chaos_shim.sh',
    'tests/test_lockkit.sh', 'tests/test_delete_propagation.sh',
    'tests/test_combined_pr.sh', 'tests/test_zero_link.sh',
    'tests/test_payload_tests_exclusion.sh', 'tests/test_payload_evidence_exclusion.sh',
)

class ContractError(ValueError): pass

def require(ok, reason):
    if not ok: raise ContractError(reason)

def digest(data): return hashlib.sha256(data).hexdigest()

def canonical(value): return json.dumps(value,sort_keys=True,separators=(',',':')).encode()

def closed(value, fields):
    require(isinstance(value,dict) and set(value)==set(fields.split()),'closed schema fields differ')

def parse(raw):
    def unique(pairs):
        d={}
        for k,v in pairs:
            require(k not in d,'duplicate JSON key');d[k]=v
        return d
    return json.loads(raw,object_pairs_hook=unique)

def identity(environment):
    names=('GITHUB_REPOSITORY','GITHUB_REPOSITORY_ID','GITHUB_EVENT_NAME','GITHUB_SHA','GITHUB_WORKFLOW_SHA','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GITHUB_REF','CI_HEAD_SHA','CI_BASE_SHA','GITHUB_WORKFLOW_REF','GITHUB_WORKFLOW')
    v={k:environment.get(n,'') for k,n in zip(IDENTITY_KEYS,names)}
    require(v['repository'] in NAMES and v['repository_id']=='1281300995','wrong repository phase/ID')
    require(v['event'] in ('push','pull_request','workflow_dispatch'),'unsupported CI event')
    for k in ('revision','workflow_sha'):require(re.fullmatch('[0-9a-f]{40}',v[k]),'invalid '+k)
    for k in ('run_id','run_attempt'):require(re.fullmatch('[1-9][0-9]*',v[k]),'invalid '+k)
    if v['event']=='pull_request':
        require(re.fullmatch(r'refs/pull/[1-9][0-9]*/merge',v['ref']),'expected merge ref')
        for k in ('head_sha','base_sha'):require(re.fullmatch('[0-9a-f]{40}',v[k]),'invalid '+k)
    else:require(v['ref']=='refs/heads/main' and v['head_sha']==v['base_sha']=='','invalid main source tuple')
    require(v['workflow']=='CI' and v['workflow_sha']==v['revision'],'wrong tested workflow')
    require(v['workflow_ref']==v['repository']+'/.github/workflows/ci.yml@'+v['ref'],'workflow phase/path/ref mismatch')
    return v

def check_checkout(expected):
    require(subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()==expected['revision'],'checkout differs')
    if expected['event']=='pull_request':
        require(subprocess.check_output(['git','show','-s','--format=%P','HEAD'],cwd=ROOT,text=True).split()==[expected['base_sha'],expected['head_sha']],'merge parent ordering differs')

def bounded(argv,timeout,cwd=ROOT):
    env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    for k in list(env):
        # Shell startup files/functions can silently displace fixture PATH stubs.
        if k.startswith(('GIT_', 'BASH_FUNC_', 'ORCH_')) or k in ('BASH_ENV', 'ENV',
                'GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN'):
            env.pop(k)
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
               XDG_CONFIG_HOME=str(Path(env['HOME'])/'.config'))
    p=subprocess.Popen(argv,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
    out=bytearray();selector=selectors.DefaultSelector();selector.register(p.stdout,selectors.EVENT_READ);deadline=time.monotonic()+timeout
    try:
        while selector.get_map():
            require(time.monotonic()<deadline,'command timeout')
            for key,_ in selector.select(min(.25,max(0,deadline-time.monotonic()))):
                data=os.read(key.fileobj.fileno(),65536)
                if not data:selector.unregister(key.fileobj);continue
                out.extend(data);require(len(out)<=MAX_OUTPUT,'command output exceeded bound')
        p.wait(timeout=max(.1,deadline-time.monotonic()))
        require(p.returncode==0,'command failed: '+str(argv)+'\n'+out.decode(errors='replace'))
        return bytes(out)
    finally:
        try:os.killpg(p.pid,signal.SIGTERM)
        except ProcessLookupError:pass
        try:p.wait(timeout=2)
        except subprocess.TimeoutExpired:pass
        try:os.killpg(p.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        p.wait();selector.close();p.stdout.close()

def run_test_module(path, output):
    file=ROOT/path;sys.path.insert(0,str(file.parent));sys.path.insert(0,str(ROOT))
    spec=importlib.util.spec_from_file_location(file.stem,file);mod=importlib.util.module_from_spec(spec);sys.modules[file.stem]=mod;spec.loader.exec_module(mod)
    suite=unittest.defaultTestLoader.loadTestsFromModule(mod)
    class Result(unittest.TextTestResult):
        def __init__(self,*a,**k):super().__init__(*a,**k);self.ids=[]
        def startTest(self,test):self.ids.append(test.id());super().startTest(test)
    result=unittest.TextTestRunner(verbosity=2,resultclass=Result).run(suite)
    skips={}
    for test,reason in result.skipped:
        # A subTest skip leaves its registered parent only partly exercised.
        # Report that whole parent unqualified; never invent an executed child ID.
        case=getattr(test,'test_case',test).id()
        require(case in result.ids and isinstance(reason,str),'skip lacks registered parent/reason')
        skips[(case,reason)]={'case':case,'reason':reason}
    value={'module':path,'cases':result.ids,'skips':list(skips.values())}
    Path(output).write_bytes(canonical(value))
    require(result.testsRun>0 and result.wasSuccessful(),'module has no tests or failed: '+path)

def policy(root=ROOT):
    raw=(root/'.github/ci-contract.json').read_bytes(); c=parse(raw)
    closed(c,'schema repository_id repository_names workflow workflow_name required_check actions_app_id reviewer_app_id shards baseline_tests')
    require(c['schema']=='orchestrator-ci-contract/v1' and type(c['repository_id']) is int
            and c['repository_id']==1281300995,'CI identity')
    require(c['repository_names']==list(NAMES) and c['shards']==list(SHARDS),'CI names/shards')
    require((c['workflow'],c['workflow_name'],c['required_check'],c['actions_app_id'],c['reviewer_app_id'])
            ==('.github/workflows/ci.yml','CI','ci-required',15368,4217367),'CI producer/workflow')
    require(c['baseline_tests']==list(BASELINE),'baseline inventory changed')
    runner=(root/'tests/run-tests.sh').read_text()
    require(re.findall(r'^run_test (tests/test_[a-z_]+[.]sh)$',runner,re.M)==list(BASELINE),
            'existing all-suite runner differs')
    mraw=(root/'.github/test-shards.json').read_bytes();m=parse(mraw)
    closed(m,'schema state aggregate discovery shards')
    require(m['schema']=='orchestrator-test-sharding/v1' and m['state']=='configured'
            and m['aggregate']=='ci-required','sharding not configured')
    require(m['discovery']=={'include':['tests/test_*.sh','tests/test_*.py'],'exclude':[]},'discovery changed')
    require([s['id'] for s in m['shards']]==list(SHARDS),'shard topology differs')
    members=[]
    for row in m['shards']:
        closed(row,'id tests command timeout_seconds')
        require(row['command']==['python3','-I','-B','scripts/verify.py','local','--shard',row['id']],
                'dispatcher differs')
        require(type(row['timeout_seconds']) is int and 1<=row['timeout_seconds']<=1800,'timeout bound')
        require(isinstance(row['tests'],list) and row['tests'] and row['tests']==sorted(set(row['tests'])),
                'missing/duplicate/unsorted tests')
        members+=row['tests']
    require(len(members)==len(set(members)),'duplicate suite ownership')
    actual={str(p.relative_to(root)) for pattern in m['discovery']['include'] for p in root.glob(pattern) if p.is_file()}
    require(set(members)==actual,'suite inventory differs from actual source')
    require({p for p in members if p.endswith('.sh')}==set(BASELINE),'shell baseline omitted/added')
    for p in members:
        target=root/p
        require(not target.is_symlink() and all(not a.is_symlink() for a in target.parents if a!=root.parent),
                'symlink suite path')
    return c,m,digest(raw+b'\0'+mraw)

def measured(shard):
    c,m,hash_=policy();row=next(s for s in m['shards'] if s['id']==shard)
    deadline=time.monotonic()+row['timeout_seconds'];cases=[];logs=[]
    # Disposable HOME makes fixture commits independent of host hooks/config and credentials.
    with tempfile.TemporaryDirectory(prefix='orchestrator-ci-') as temp:
        old_home=os.environ.get('HOME');os.environ['HOME']=temp
        try:
            for i,path in enumerate(row['tests']):
                if path.endswith('.sh'):
                    out=bounded(['bash',path],max(1,deadline-time.monotonic()))
                    cases.append(path+'::suite')
                else:
                    target=Path(temp)/str(i)
                    out=bounded([sys.executable,'-I','-B',str(Path(__file__)),'module','--module',path,
                                 '--output',str(target)],max(1,deadline-time.monotonic()))
                    result=parse(target.read_bytes());closed(result,'module cases skips')
                    require(result['module']==path and result['cases'] and not result['skips'],'empty/wrong/skipped case evidence')
                    cases.extend(path+'::'+case for case in result['cases'])
                print(path+': OK')
                print(out.decode(errors='replace'))
                logs.append({'id':path,'sha256':digest(out)})
        finally:
            if old_home is None:os.environ.pop('HOME',None)
            else:os.environ['HOME']=old_home
    require(len(cases)==len(set(cases)) and cases,'duplicate/zero executed cases')
    return {'tests':row['tests'],'shell_suites':[p for p in row['tests'] if p.endswith('.sh')],
            'case_count':len(cases),'case_ids_sha256':digest(canonical(cases)),
            'logs_sha256':digest(canonical(logs)),'contract_sha256':hash_}

def validate_measurement(value,shard,c,m,hash_):
    closed(value,'tests shell_suites case_count case_ids_sha256 logs_sha256 contract_sha256')
    row=next(s for s in m['shards'] if s['id']==shard)
    require(value['tests']==row['tests'] and value['shell_suites']==[p for p in row['tests'] if p.endswith('.sh')]
            and value['contract_sha256']==hash_,'stale coverage/contract')
    require(type(value['case_count']) is int and value['case_count']>=len(row['tests']),'zero/partial cases')
    for k in ('case_ids_sha256','logs_sha256'):
        require(isinstance(value[k],str) and re.fullmatch('[0-9a-f]{64}',value[k]),'case/log digest missing')

def validate_aggregate(needs,expected):
    c,m,hash_=policy()
    require(isinstance(needs,dict) and set(needs)==set(SHARDS),'missing or extra shard')
    for shard in SHARDS:
        row=needs[shard];closed(row,'result outputs');require(row['result']=='success','shard failed/skipped/cancelled')
        closed(row['outputs'],'receipt');receipt=parse(row['outputs']['receipt'])
        closed(receipt,'schema shard identity result measurement')
        require(receipt['schema']=='orchestrator-ci-shard/v1' and receipt['shard']==shard
                and receipt['identity']==expected and receipt['result']=='success','stale shard receipt')
        validate_measurement(receipt['measurement'],shard,c,m,hash_)
    return hash_

def main():
    p=argparse.ArgumentParser();p.add_argument('mode',choices=('local','shard','aggregate','module'))
    p.add_argument('--shard',choices=SHARDS);p.add_argument('--module');p.add_argument('--output');a=p.parse_args()
    if a.mode=='module':
        require(a.module in {p for s in parse((ROOT/'.github/test-shards.json').read_bytes())['shards']
                            for p in s['tests'] if p.endswith('.py')} and a.output,'unknown module/output')
        run_test_module(a.module,a.output);return
    require(a.module is None and a.output is None,'unexpected module options')
    if a.mode=='local':
        for shard in (a.shard,) if a.shard else SHARDS:
            print(json.dumps({'shard':shard,'measurement':measured(shard)},sort_keys=True))
        print('Local fixture checks passed; hosted/account/App/publication qualification is separate');return
    expected=identity(dict(os.environ));check_checkout(expected)
    if a.mode=='shard':
        require(a.shard is not None,'shard required');measurement=measured(a.shard)
        output=os.environ.get('GITHUB_OUTPUT');require(output,'GITHUB_OUTPUT required')
        receipt={'schema':'orchestrator-ci-shard/v1','shard':a.shard,'identity':expected,
                 'result':'success','measurement':measurement}
        with open(output,'a') as f:f.write('receipt='+canonical(receipt).decode()+'\n')
    else:
        require(a.shard is None,'aggregate cannot select shard')
        hash_=validate_aggregate(parse(os.environ.get('CI_NEEDS','null')),expected)
        print('ORCHESTRATOR_CI_AGGREGATE_V1 '+canonical({'schema':'orchestrator-ci-aggregate/v1',
              'identity':expected,'result':'success','contract_sha256':hash_}).decode())
if __name__=='__main__':
    try:main()
    except (ContractError,ValueError,OSError,subprocess.SubprocessError,KeyError,TypeError) as e:
        print('CI verification refused: '+str(e),file=sys.stderr);sys.exit(1)

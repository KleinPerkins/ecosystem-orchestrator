"""Closed fixture coverage and exact-run aggregate regression tests; no network."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('orchestrator_ci',ROOT/'scripts/verify.py')
ci=importlib.util.module_from_spec(spec);spec.loader.exec_module(ci)
ENV=dict(GITHUB_REPOSITORY='KleinPerkins/ecosystem-orchestrator',GITHUB_REPOSITORY_ID='1281300995',
 GITHUB_EVENT_NAME='pull_request',GITHUB_SHA='a'*40,GITHUB_WORKFLOW_SHA='a'*40,GITHUB_RUN_ID='100',
 GITHUB_RUN_ATTEMPT='2',GITHUB_REF='refs/pull/12/merge',CI_HEAD_SHA='c'*40,CI_BASE_SHA='d'*40,
 GITHUB_WORKFLOW_REF='KleinPerkins/ecosystem-orchestrator/.github/workflows/ci.yml@refs/pull/12/merge',
 GITHUB_WORKFLOW='CI')

def evidence():
 c,m,h=ci.policy()
 return {s['id']:{'result':'success','outputs':{'receipt':json.dumps({
  'schema':'orchestrator-ci-shard/v1','shard':s['id'],'identity':ci.identity(ENV),'result':'success',
  'measurement':{'tests':s['tests'],'shell_suites':[p for p in s['tests'] if p.endswith('.sh')],
  'case_count':len(s['tests']),'case_ids_sha256':'a'*64,'logs_sha256':'b'*64,'contract_sha256':h}})}}
  for s in m['shards']}

class Receipts(unittest.TestCase):
 def test_exact_union(self):ci.validate_aggregate(evidence(),ci.identity(ENV))
 def test_missing_extra_and_duplicate_shards(self):
  n=evidence();cases=[None,{},dict(n,extra={})]
  x=copy.deepcopy(n);x.pop(ci.SHARDS[0]);cases.append(x)
  x=copy.deepcopy(n);x[ci.SHARDS[1]]=x[ci.SHARDS[0]];cases.append(x)
  for value in cases:
   with self.subTest(value=value),self.assertRaises(ci.ContractError):ci.validate_aggregate(value,ci.identity(ENV))
 def test_non_success_refuses(self):
  for shard in ci.SHARDS:
   for status in ('failure','cancelled','skipped','neutral','timed_out','',None):
    n=evidence();n[shard]['result']=status
    with self.subTest(shard=shard,status=status),self.assertRaises(ci.ContractError):ci.validate_aggregate(n,ci.identity(ENV))
 def mutate(self,change):
  n=evidence();r=json.loads(n[ci.SHARDS[0]]['outputs']['receipt']);change(r)
  n[ci.SHARDS[0]]['outputs']['receipt']=json.dumps(r)
  with self.assertRaises(ci.ContractError):ci.validate_aggregate(n,ci.identity(ENV))
 def test_every_identity_field_bound(self):
  for k in ci.IDENTITY_KEYS:self.mutate(lambda r:r['identity'].__setitem__(k,r['identity'][k]+'stale'))
 def test_schema_and_measurement(self):
  for change in (lambda r:r.update(schema='wrong'),lambda r:r.update(extra=True),lambda r:r.update(result='failed'),lambda r:r.update(shard='other')):self.mutate(change)
  for k,v in [('tests',[]),('shell_suites',[]),('case_count',0),('case_count',True),('contract_sha256','f'*64),('logs_sha256',''),('case_ids_sha256','x')]:
   self.mutate(lambda r,k=k,v=v:r['measurement'].__setitem__(k,v))
 def test_duplicate_keys_and_malformed_refuse(self):
  for raw in ('null','[]','{}','not JSON','{"schema":1,"schema":2}'):
   n=evidence();n[ci.SHARDS[0]]['outputs']['receipt']=raw
   with self.subTest(raw=raw),self.assertRaises((ci.ContractError,ValueError)):ci.validate_aggregate(n,ci.identity(ENV))

class IdentityAndProcess(unittest.TestCase):
 def test_required_fields(self):
  for key in ENV:
   with self.subTest(key=key),self.assertRaises(ci.ContractError):ci.identity(dict(ENV,**{key:''}))
 def test_closed_identity_event_matrix(self):
  for change in ({'GITHUB_REPOSITORY_ID':'1459458379'},{'GITHUB_REPOSITORY':'other/orchestrator'},
                 {'GITHUB_EVENT_NAME':'pull_request_target'},{'GITHUB_RUN_ATTEMPT':'0'},
                 {'GITHUB_WORKFLOW_SHA':'b'*40},{'GITHUB_WORKFLOW_REF':'other/workflow'}):
   with self.subTest(change=change),self.assertRaises(ci.ContractError):ci.identity(dict(ENV,**change))
  for event in ('push','workflow_dispatch'):
   env=dict(ENV,GITHUB_EVENT_NAME=event,GITHUB_REF='refs/heads/main',CI_HEAD_SHA='',CI_BASE_SHA='',
    GITHUB_WORKFLOW_REF=ENV['GITHUB_REPOSITORY']+'/.github/workflows/ci.yml@refs/heads/main')
   self.assertEqual(ci.identity(env)['event'],event)
   with self.assertRaises(ci.ContractError):ci.identity(dict(env,GITHUB_REF='refs/heads/topic'))
 def test_shell_startup_and_credentials_removed(self):
  with tempfile.TemporaryDirectory() as temp:
   startup=Path(temp)/'startup';marker=Path(temp)/'marker';startup.write_text('touch '+str(marker)+'\n')
   with patch.dict(os.environ,{'BASH_ENV':str(startup),'ENV':str(startup),'GH_TOKEN':'fixture',
                              'BASH_FUNC_bad%%':'() { echo bad; }','GIT_DIR':'/invalid','ORCH_TEST_CPP_DIR':'/must-not-use-host'}):
    self.assertEqual(ci.bounded(['bash','-c','test -z "${BASH_ENV+x}${ENV+x}${GH_TOKEN+x}${GIT_DIR+x}${ORCH_TEST_CPP_DIR+x}" && printf clean'],5),b'clean')
   self.assertFalse(marker.exists())
 def test_timeout_output_and_failure_refuse(self):
  for argv,timeout in [([sys.executable,'-c','import time; time.sleep(5)'],.05),
                        ([sys.executable,'-c','raise SystemExit(2)'],5)]:
   with self.assertRaises(ci.ContractError):ci.bounded(argv,timeout)
  with patch.object(ci,'MAX_OUTPUT',10),self.assertRaises(ci.ContractError):
   ci.bounded([sys.executable,'-c','print("x"*100)'],5)

class InventoryAndWorkflow(unittest.TestCase):
 def fixture(self,root):
  for name in ('.github/ci-contract.json','.github/test-shards.json','tests/run-tests.sh'):
   target=root/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/name).read_bytes())
  for row in ci.policy()[1]['shards']:
   for name in row['tests']:(root/name).write_text('# fixture\n')
 def test_inventory_is_closed_and_complete(self):
  c,m,h=ci.policy();members=[p for s in m['shards'] for p in s['tests']]
  self.assertEqual(len(members),len(set(members)))
  self.assertEqual({p for p in members if p.endswith('.sh')},set(ci.BASELINE))
  with tempfile.TemporaryDirectory() as temp:
   root=Path(temp);self.fixture(root);ci.policy(root)
   extra=root/'tests/test_unassigned.sh';extra.touch()
   with self.assertRaises(ci.ContractError):ci.policy(root)
   extra.unlink();missing=root/members[0];missing.unlink()
   with self.assertRaises(ci.ContractError):ci.policy(root)
 def test_existing_shell_runner_cannot_omit_suite(self):
  with tempfile.TemporaryDirectory() as temp:
   root=Path(temp);self.fixture(root);p=root/'tests/run-tests.sh'
   p.write_text(p.read_text().replace('run_test '+ci.BASELINE[0],'# omitted'))
   with self.assertRaises(ci.ContractError):ci.policy(root)
 def test_workflow_is_read_only_and_exact(self):
  w=ci.parse((ROOT/'.github/workflows/ci.yml').read_bytes())
  self.assertEqual(set(w['on']),{'push','pull_request','workflow_dispatch'})
  self.assertEqual(w['permissions'],{'contents':'read'})
  self.assertEqual(set(w['jobs']),set(ci.SHARDS)|{'ci-required'})
  self.assertEqual(w['jobs']['ci-required']['needs'],list(ci.SHARDS))
  self.assertEqual(w['jobs']['ci-required']['if'],'${{ always() }}')
  for name,job in w['jobs'].items():
   self.assertEqual(job['runs-on'],'ubuntu-24.04');self.assertNotIn('permissions',job)
   for step in job['steps']:
    self.assertNotIn('continue-on-error',step)
    if 'uses' in step:
     self.assertIn(step['uses'],['actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1',
                                'actions/setup-python@e797f83bcb11b83ae66e0230d6156d7c80228e7c'])
     if step['uses'].startswith('actions/checkout'):
      self.assertEqual(step['with'],{'ref':'${{ github.sha }}','persist-credentials':False,'fetch-depth':0})
   command=job['steps'][-1]
   if name in ci.SHARDS:
    self.assertEqual(command['run'],'python3 -I -B scripts/verify.py shard --shard '+name)
    self.assertEqual(job['outputs'],{'receipt':'${{ steps.verify.outputs.receipt }}'})
   else:
    self.assertEqual(command['run'],'python3 -I -B scripts/verify.py aggregate')
    self.assertEqual(command['env']['CI_NEEDS'],'${{ toJSON(needs) }}')
 def test_source_admission_binds_actual_creator_adapters_and_current_profile(self):
  p=ci.parse((ROOT/'.github/review-enrollments.json').read_bytes())
  self.assertEqual((p['schema'],p['repository_id'],p['repository_names']),
   ('g1-review-enrollments/v1',1281300995,['KleinPerkins/ecosystem-orchestrator']))
  self.assertIs(p['enabled'],True)
  self.assertEqual(len(p['producers']),1)
  producer=p['producers'][0]
  self.assertIs(producer['enabled'],True)
  self.assertEqual((producer['id'],producer['github_user_id'],producer['origin_account']),
   ('enrollment-24c0a5f2',49759187,'origin-7612de79'))
  self.assertEqual((producer['cli_version'],producer['credential_store']),('codex-cli 0.148.0','keyring'))
  for key,path in [('capture_adapter_sha256','scripts/local_review.py'),
                   ('creation_adapter_sha256','scripts/create_review_pr.py')]:
   self.assertEqual(producer[key],ci.digest((ROOT/path).read_bytes()))
  spec=importlib.util.spec_from_file_location('enrolled_capture',ROOT/'scripts/local_review.py')
  capture=importlib.util.module_from_spec(spec);spec.loader.exec_module(capture)
  self.assertEqual(producer['instructions_sha256'],capture.digest(capture.INSTRUCTIONS))
  self.assertEqual(set(producer['allowed_startup_notice_sha256']),
                   {capture.digest(item) for item in capture.STARTUP_NOTICES})
  self.assertEqual(p['governance']['phase'],'G1-source-producer-admitted')
  spec=importlib.util.spec_from_file_location('enrolled_app',ROOT/'scripts/reviewer_app.py')
  app=importlib.util.module_from_spec(spec);spec.loader.exec_module(app)
  self.assertEqual(p['governance']['qualified_app_identity']['installation_id'],app.INSTALLATION_ID)
  self.assertEqual(p['governance']['qualified_app_identity']['app_id'],app.APP_ID)

if __name__=='__main__':unittest.main()

#!/usr/bin/env python3
"""Run deliberate defects ONLY in temporary service source copies on the test stack.

A mutant counts as caught only if the selected HTTP assertion fails with an
unexpected successful response. Boot failures, syntax errors and empty suites
are infrastructure failures, never evidence that the authorization test works.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
# (name, source, exact replacement, selected example substring)
MUTANTS = [
    ('account_gate', 'account-service/app/controllers/accounts_controller.rb',
     'def authorize_account_collection_read!(accounts)', 'def authorize_account_collection_read!(accounts)\n    return', 'account respects read grant at child'),
    ('user_gate', 'user-service/app/controllers/users_controller.rb',
     'def authorize_user_collection_read!(users)', 'def authorize_user_collection_read!(users)\n    return', 'user respects users grant at child'),
    ('group_gate', 'group-service/app/controllers/groups_controller.rb',
     'def authorize_group_collection_read!(groups)', 'def authorize_group_collection_read!(groups)\n    return', 'group respects users grant at child'),
    ('membership_gate', 'group-service/app/controllers/group_users_controller.rb',
     'def authorize_group_user_collection_read!(group_users)', 'def authorize_group_user_collection_read!(group_users)\n    return', 'membership respects users grant at child'),
    ('relationship_gate', 'organization-service/app/controllers/organization_accounts_controller.rb',
     'def authorize_relationship_read!(actor, relationship)', 'def authorize_relationship_read!(actor, relationship)\n    return', 'organization_relationship respects read grant at child'),
    ('organization_gate', 'organization-service/app/controllers/organizations_controller.rb',
     'if pad_user_id != "IAM_SYSTEM"', 'if false', 'organization records and account enumeration'),
    ('user_count_gate', 'user-service/app/controllers/users_counts_controller.rb',
     'def authorize_account_user_counts!(account_ids)', 'def authorize_account_user_counts!(account_ids)\n    return', 'users counts authorize'),
    ('group_count_gate', 'group-service/app/controllers/groups_counts_controller.rb',
     'def authorize_account_group_counts!(account_ids)', 'def authorize_account_group_counts!(account_ids)\n    return', 'groups counts authorize'),
    ('hierarchy_output_gate', 'account-service/app/controllers/accounts_controller.rb',
     'def authorize_hierarchy_records!(actor, hierarchies)', 'def authorize_hierarchy_records!(actor, hierarchies)\n    return', 'hierarchy records require'),
    ('organization_count_gate', 'organization-service/app/controllers/organizations/accounts_count_controller.rb',
     'if pad_user_id != "IAM_SYSTEM" && !organization_accounts_read?(pad_user_id, org_id)', 'if false', 'organization records and account enumeration'),
    ('organization_enumeration_gate', 'organization-service/app/controllers/organization_accounts_controller.rb',
     'unless actor == "IAM_SYSTEM" || organization_accounts_read?(actor, organization_ids)', 'unless true', 'organization context requires'),
    ('msp_page_gate', 'organization-service/app/models/user.rb',
     'def self.user_can(user_id, scope_type, permission, scope_id)', 'def self.user_can(user_id, scope_type, permission, scope_id)\n    return true', 'MSP pages require'),
    ('internal_group_gate', 'group-service/app/controllers/internal/auth/contexts_controller.rb',
     'def require_auth_system!', 'def require_auth_system!\n        return', 'internal record and relationship'),
    ('internal_organization_facts_gate', 'organization-service/app/controllers/internal/auth/account_contexts_controller.rb',
     'def require_iam_system_auth!', 'def require_iam_system_auth!\n        return true', 'internal record and relationship'),
    ('internal_admin_gate', 'authorization-service/app/controllers/internal/admin_users_controller.rb',
     'def require_iam_system!', 'def require_iam_system!\n      return true', 'internal record and relationship'),
    ('internal_random_gate', 'organization-service/app/controllers/internal/random_records_controller.rb',
     'def require_iam_system!', 'def require_iam_system!\n      return true', 'internal record and relationship'),
    ('internal_msp_gate', 'organization-service/app/controllers/internal/msp_managed_organizations_controller.rb',
     'def require_internal_system!', 'def require_internal_system!\n      return true', 'internal record and relationship'),
    ('batch_any_target', 'authorization-service/app/controllers/can_controller.rb',
     'requested_account_ids.all? { |account_id| authorized_account_ids.include?(account_id) }',
     'requested_account_ids.any? { |account_id| authorized_account_ids.include?(account_id) }', 'account respects read grant at child'),
    ('scope_is_ignored', 'authorization-service/lib/authorization/capabilities.rb',
     'def account_scope_ids_for(account_ids)', 'def account_scope_ids_for(account_ids)\n      return account_ids.to_h { |id| [id, CapabilityGrant.where(group_id: group_ids, scope_type: "Account").distinct.pluck(:scope_id)] }', 'account respects read grant at child'),
    ('permission_is_ignored', 'authorization-service/lib/authorization/capabilities.rb',
     '.distinct.pluck(:permission).sort\n      end\n    end\n\n    def for_group',
     '.distinct.pluck(:permission).then { |ps| ps.empty? ? [] : %w[account.read account.users.read] }\n      end\n    end\n\n    def for_group', 'user rejects wrong permission'),
    ('membership_is_ignored', 'authorization-service/lib/authorization/capabilities.rb',
     '@group_ids ||= @group_context_client.group_ids_for(@user_id)', '@group_ids ||= CapabilityGrant.distinct.pluck(:group_id)', 'user rejects wrong permission'),
    ('exact_group_scope_is_ignored', 'authorization-service/lib/authorization/capabilities.rb',
     'CapabilityGrant.where(group_id: group_ids, scope_type: "Group", scope_id: group_id)', 'CapabilityGrant.where(group_id: group_ids, scope_type: "Group")', 'group and membership exact grants'),
]
ENV_KEYS = {s: s.replace('-', '_').upper() + '_TEST_SOURCE_PATH' for s in
            ['account-service', 'user-service', 'group-service', 'organization-service', 'authorization-service']}

def run_specs(destination, example, mode):
    destination.mkdir(parents=True, exist_ok=True)
    for name in ['results.json', 'requests.jsonl']:
        (destination / name).unlink(missing_ok=True)
    command = ['./dc_test', 'run', '--rm', '--no-deps', '-T', '-v', f'{ROOT}:/workspace:ro',
               '-v', f'{destination}:/evidence', '-e', f'AUTHORIZATION_CHECK_MODE={mode}',
               '-e', 'GLOBAL_IAM_DEMO_USE_REDIS=false', '-e', 'PROOF_LEDGER=/evidence/requests.jsonl',
               'authorization-service', 'bundle', 'exec', 'rspec',
               '/workspace/test/integration/record_authorization_spec.rb', '--example-matches', example,
               '--format', 'json', '--out', '/evidence/results.json']
    with (destination / 'run.log').open('w') as log:
        run = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    result_file = destination / 'results.json'
    report = json.loads(result_file.read_text()) if result_file.exists() else {}
    return run.returncode, report


def restart(identities):
    subprocess.run(['docker', 'restart', *identities], check=True, stdout=subprocess.DEVNULL)
    for identity in identities:
        for attempt in range(60):
            check = subprocess.run(['docker', 'exec', identity, 'curl', '-fsS', 'http://localhost:80/up'],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if check.returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError(f'Mutant service {identity} did not become ready')


def running_profile():
    mode = os.environ['AUTHORIZATION_CHECK_MODE']
    sources = json.loads(os.environ['PROOF_MUTATION_SOURCES'])
    output = Path(os.environ['PROOF_OUTPUT'])
    containers = dict(line.split() for line in (output / 'containers.txt').read_text().splitlines())
    results = []
    (output / 'summary.json').unlink(missing_ok=True)
    requested = os.environ.get('PROOF_MUTANTS', '').split(',')
    if requested[0]:
        assert set(requested) <= {m[0] for m in MUTANTS}, 'Unknown mutation selection'
    for name, source, before, after, example in MUTANTS:
        if requested[0] and name not in requested:
            continue
        # Trusted-context guards do not branch on the authorization protocol.
        if mode == 'capabilities' and name.startswith('internal_'):
            continue
        if name == 'batch_any_target' and mode == 'capabilities':
            source = 'account-service/app/models/user.rb'
            before = 'scope_ids.all? { |scope_id| Array(capabilities_by_scope[scope_id]).include?(permission) }'
            after = 'scope_ids.any? { |scope_id| Array(capabilities_by_scope[scope_id]).include?(permission) }'
        service, relative = source.split('/', 1)
        target = Path(sources[service]) / relative
        original = target.read_text()
        assert original.count(before) == 1, (name, original.count(before))
        changed = original.replace(before, after)
        if name == 'permission_is_ignored':
            assert 'scope_id: direct_scope_ids, permission: permission)' in changed
            changed = changed.replace('scope_id: direct_scope_ids, permission: permission)', 'scope_id: direct_scope_ids)')
        affected = [containers[service]]
        fact_service = service.replace('-service', '-auth-service')
        if fact_service in containers:
            affected.append(containers[fact_service])
        destination = output / name
        try:
            target.write_text(changed)
            restart(affected)
            code, report = run_specs(destination, example, mode)
        finally:
            target.write_text(original)
            restart(affected)
        failed = [e for e in report.get('examples', []) if e['status'] == 'failed']
        caught = code != 0 and bool(failed) and all(
            e.get('exception', {}).get('class') == 'RSpec::Expectations::ExpectationNotMetError'
            and ': 200 ' in e.get('exception', {}).get('message', '') for e in failed)
        # Causal control: the exact same selected tests must pass after restoring
        # the source and restarting the same service(s).
        restored_code, restored = run_specs(destination / 'restored', example, mode)
        control_passed = (restored_code == 0 and restored.get('summary', {}).get('example_count', 0) > 0
                          and restored.get('summary', {}).get('failure_count') == 0
                          and restored.get('summary', {}).get('pending_count') == 0)
        record = {'mutation': name, 'mode': mode, 'caught': caught, 'restored_passed': control_passed,
                  'exit': code, 'source': source, 'before': before, 'after': after,
                  'failed_examples': [e['full_description'] for e in failed]}
        results.append(record)
        (output / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
        print(f'{mode} {name}: caught={caught}, restored={control_passed}', flush=True)
        if not (caught and control_passed):
            raise SystemExit(f'Mutation proof failed; inspect {destination}')


def main():
    output = Path(os.environ.get('PROOF_MUTATION_OUTPUT', ROOT / 'reports/raw/record-authorization/mutations')).resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='iam-record-mutants-') as work:
        os.chmod(work, 0o755)
        sources = {}
        for service in ENV_KEYS:
            copy = Path(work) / service
            shutil.copytree(ROOT / service, copy, ignore=shutil.ignore_patterns('log', 'tmp', 'node_modules', '.git', 'storage', 'vendor'))
            for directory in ['log', 'tmp', 'storage']:
                (copy / directory).mkdir(exist_ok=True)
            sources[service] = str(copy)
        for mode in ['can', 'capabilities']:
            destination = output / mode
            destination.mkdir(exist_ok=True)
            env = dict(os.environ, AUTHORIZATION_CHECK_MODE=mode, GLOBAL_IAM_DEMO_USE_REDIS='false',
                       PROOF_SKIP_SEED='1', PROOF_SKIP_ROUTES='1', PROOF_SKIP_EXISTING='1',
                       PROOF_MUTATION_DRIVER='1', PROOF_MUTATION_SOURCES=json.dumps(sources),
                       PROOF_OUTPUT=str(destination), **{ENV_KEYS[s]: path for s, path in sources.items()})
            with (destination / 'stack.log').open('w') as log:
                run = subprocess.run(['bash', 'scripts/test_record_authorization.sh'], cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
            if run.returncode:
                raise SystemExit(f'Mutation profile failed; inspect {destination}')
            print(f'{mode}: mutation profile passed', flush=True)


if __name__ == '__main__':
    running_profile() if '--running-profile' in sys.argv else main()

#!/usr/bin/env python3
"""Strict offline hc/herdr-app stand-ins; never spawn or contact either app."""
import json
import os
from pathlib import Path
import sys

root = Path(os.environ['FM_HC_TEST_WORLD'])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as stream:
    stream.write(json.dumps([name, *args]) + '\n')
world = json.loads((root / 'world.json').read_text())

def save():
    (root / 'world.json').write_text(json.dumps(world))

def emit(value):
    print(json.dumps(value))

if world.get('fail') == [name, *args]:
    sys.exit(1)
if world.get('reply', {}).get('args') == [name, *args]:
    emit(world['reply']['value'])
    sys.exit(0)
if name == 'hc':
    if args == ['ls', '--all', '--json']:
        # ls returns summaries; ownership labels are available through get only.
        terminals = world['terminals']
        emit({'terminals': [{k: v for k, v in t.items() if k != 'labels'}
                            for t in terminals] if isinstance(terminals, list) else terminals})
    elif args[0] == 'get' and len(args) == 3 and args[2] == '--json':
        matches = [t for t in world['terminals'] if t['address'] == args[1]]
        if not matches:
            sys.exit(3)
        emit(matches[0])
    elif args[0] == 'label' and len(args) == 6:
        assert [label.split('=', 1)[0] for label in args[2:]] == [
            'fm.home', 'fm.task', 'fm.owner', 'fm.home-hash']
        terminal = next(t for t in world['terminals'] if t['address'] == args[1])
        for label in args[2:]:
            key, value = label.split('=', 1)
            terminal['labels'][key] = value
        save()
    elif args[0] == 'read' and len(args) == 4 and args[2] == '--lines':
        if world.get('send_attempts') == 1:
            world['read_after_block'] = True
            save()
        print(world.get('screen', 'one\ntwo\n❯'))
    elif args[0] == 'send':
        send_args = args[1:]
        flags = send_args[:send_args.index('--')]
        forced = '--force' in flags
        flags = [v for v in flags if v not in ('--force', '--json')]
        assert len(flags) == 1 and send_args[-2] == '--'
        terminal = next(t for t in world['terminals'] if t['address'] == flags[0])
        policy = world.get('send_policy')
        if policy is not None:
            attempts = world.get('send_attempts', 0) + 1
            world['send_attempts'] = attempts
            assert not world.get('delivered'), 'second submitted send is forbidden'
            assert attempts == (2 if forced else 1), 'unexpected repeated send'
            if forced:
                assert policy['kind'] == 'blocked', 'force without blocked refusal'
                assert world.get('read_after_block'), 'force without fresh capture'
            kind = policy.get('force_kind', '') if forced else policy['kind']
            save()
            if kind:
                print(json.dumps({'error': {'kind': kind, 'hint':
                    'typing would answer its dialog; read its screen first, or --force'}}), file=sys.stderr)
                sys.exit(9 if kind == 'blocked' else 1)
            world['delivered'] = send_args[-1]
            save()
        else:
            assert not forced, 'force requires an explicit fixture policy'
        if send_args[-1] == 'treehouse get':
            terminal['foreground']['cwd'] = os.environ['FM_FAKE_PANE_PATH']
            save()
        emit({'started': True})
    elif args[0] == 'keys' and len(args) == 3 and args[2] in ('enter', 'esc', 'ctrl+u', 'ctrl+c'):
        emit({})
    elif args[0] == 'interrupt' and len(args) == 2:
        emit({'outcome': 'stopped'})
    elif args[0] == 'kill' and len(args) == 2:
        next(t for t in world['terminals'] if t['address'] == args[1])['state'] = 'finished'
        save()
    elif args[0] == 'rm' and len(args) == 2:
        terminal = next(t for t in world['terminals'] if t['address'] == args[1])
        assert terminal['state'] == 'finished'
        world['terminals'].remove(terminal)
        save()
    else:
        raise AssertionError(('unsupported hc call', args))
elif name == 'herdr-app':
    if args == ['ls']:
        emit({'spaces': world['spaces']})
    elif args[:2] == ['do', 'space.new'] and args[2::2] == ['--name', '--folder', '--argv']:
        assert json.loads(args[7]) == ['/bin/bash', '-l']
        n = world.get('next', 1)
        space, tab, terminal = f's{n}', f'tab{n}', f't{n}'
        world['next'] = n + 1
        world['spaces'].append({'id': space, 'name': args[3], 'tabs': [{'id': tab}]})
        world['terminals'].append({'address': terminal, 'state': 'live', 'status': None,
            'labels': {'herdr.space': space, 'herdr.tab': tab},
            'foreground': {'cwd': args[5]}})
        save()
        emit({'space': space, 'tab': tab, 'terminal': terminal})
    elif args[:3] == ['do', 'space.close', '--id'] and args[4:] == ['--confirmed', 'true']:
        world['spaces'] = [s for s in world['spaces'] if s['id'] != args[3]]
        save()
        emit({})
    else:
        raise AssertionError(('unsupported herdr-app call', args))
else:
    raise AssertionError(('unknown tool', name))

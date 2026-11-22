import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location('deploy', Path(__file__).with_name('deploy.py'))
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


def build_dir(root: Path) -> Path:
    build = root / 'cloud-web'
    build.mkdir()
    (build / 'index.html').write_text('<!doctype html>\n')
    (build / 'build.json').write_text(json.dumps({'version': '0.1.9999', 'revision': 'abc'}) + '\n')
    return build


class WebJsonAccount(unittest.TestCase):
    # `r2 object put` takes no --config: the account must be given by CLOUDFLARE_ACCOUNT_ID, or wrangler takes the
    # one the deploy before cached (still.fail's, when stable deploys monoid's next).
    def test_put_names_the_account_over_the_environment(self):
        with tempfile.TemporaryDirectory() as root, \
                mock.patch.dict(os.environ, {'CLOUDFLARE_ACCOUNT_ID': 'cached-other', 'KEPT': 'yes'}), \
                mock.patch.object(deploy, 'wrangler') as wrangler:
            build = build_dir(Path(root))
            deploy.say_web_build(build, beta=False, account='monoid-account')
            deploy.say_web_build(build, beta=True, account='monoid-account', env={'GIVEN': '1', 'CLOUDFLARE_ACCOUNT_ID': 'x'})
        first, second = wrangler.call_args_list
        self.assertEqual(first.args[:4], ('r2', 'object', 'put', 'stillfail-releases/web.json'))
        self.assertEqual(first.kwargs['env']['CLOUDFLARE_ACCOUNT_ID'], 'monoid-account')
        self.assertEqual(first.kwargs['env']['KEPT'], 'yes')
        self.assertEqual(second.args[3], 'stillfail-releases/web-beta.json')
        self.assertEqual(second.kwargs['env'], {'GIVEN': '1', 'CLOUDFLARE_ACCOUNT_ID': 'monoid-account'})

    def test_promote_web_uses_one_account_for_deploy_and_put(self):
        response = mock.MagicMock()
        response.__enter__.return_value.status = 200
        templates = {name: deploy.read_template(name) for name in ('wrangler.jsonc', deploy.PARTS['web'])}
        with tempfile.TemporaryDirectory() as root, \
                mock.patch.object(deploy, 'ROOT', Path(root)), \
                mock.patch.object(deploy, 'read_template', lambda name='wrangler.jsonc': json.loads(json.dumps(templates[name]))), \
                mock.patch.object(deploy, 'account_id', return_value='monoid-account') as account_id, \
                mock.patch.object(deploy, 'wrangler') as wrangler, \
                mock.patch.object(deploy.urllib.request, 'urlopen', return_value=response):
            build = build_dir(Path(root))
            deploy.promote_web(str(build))
            local = json.loads((Path(root) / 'wrangler.web.local.json').read_text())
        account_id.assert_called_once_with()
        self.assertEqual(local['account_id'], 'monoid-account')
        self.assertEqual(local['assets']['directory'], str(build.resolve()))
        deployed, put = wrangler.call_args_list
        self.assertEqual(deployed.args[0], 'deploy')
        self.assertEqual(put.args[:3], ('r2', 'object', 'put'))
        self.assertEqual(put.kwargs['env']['CLOUDFLARE_ACCOUNT_ID'], 'monoid-account')


if __name__ == '__main__': unittest.main()

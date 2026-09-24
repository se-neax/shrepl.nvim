-- nvim --headless -u NONE --cmd 'set rtp^=.' -l tests/confirm.lua
local shrepl = require('shrepl')
local api = vim.api
local ns = api.nvim_get_namespaces().shrepl

local asked, answer = {}, 2 -- 1 = Run, 2 = Cancel
vim.fn.confirm = function(msg) table.insert(asked, msg); return answer end

local buf = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(buf)
local function mark_at(row)
  local m = api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true })[1]
  return m and m[4].virt_text[1][1]
end
local function run(cmd)
  asked = {}
  api.nvim_buf_set_lines(buf, 0, -1, false, { cmd })
  shrepl.eval(buf, 0, 0)
  return #asked > 0
end

-- matcher only: none of these may ever reach a shell
for _, cmd in ipairs({
  'rm -rf /tmp/x', 'rm notes.txt', 'aws s3 rm s3://b/k', 'aws s3 sync . s3://b',
  'aws s3 cp f.txt s3://b/k', 'aws s3api delete-object --bucket b --key k',
  'aws lambda invoke --function-name f out.json', 'aws ec2 terminate-instances --instance-ids i-1',
  'kubectl delete pod web-1', 'kubectl apply -f x.yaml', 'terraform apply', 'terraform destroy',
  'git push --force', 'git push -f origin master', 'git reset --hard HEAD~1',
  'psql -c "DELETE FROM users"', 'echo "DROP TABLE users;" | psql', 'dd if=/dev/zero of=x',
  'terraform -chdir=infra destroy', 'kubectl -n prod delete pod web', 'git -C repo reset --hard',
  'aws --profile prod s3 rm s3://b/k', 'dd bs=4M if=image.iso of=/dev/sda', 'dd of=/dev/sda if=x',
  'aws s3 cp file "s3://bucket/key"', 'git clean -d -f', 'git clean --force -d', 'git push -fu origin main', 'aws s3 cp file s3://bucket/key --acl private', 'aws s3 cp s3://a/k s3://b/k',
}) do assert(shrepl.needs_confirm({ cmd }), 'should ask: ' .. cmd) end

for _, cmd in ipairs({
  'aws s3 ls s3://b', 'aws s3api list-buckets', 'aws lambda list-functions', 'aws s3 cp s3://b/k .',
  'aws logs describe-log-groups', 'kubectl get pods', 'git push origin master', 'terraform plan',
  'echo form -rf', 'ls -rf', 'grep -r remove .', 'git push -u origin main', 'git clean -n', 'dd --help',
}) do assert(not shrepl.needs_confirm({ cmd }), 'should not ask: ' .. cmd) end
assert(shrepl.needs_confirm({ 'echo ok', '  rm -rf /tmp/x' }) == 'rm -rf /tmp/x', 'reports the matching line')
assert(shrepl.needs_confirm({ 'terraform \\', '  destroy -auto-approve' }), 'backslash continuation is one command')
assert(not shrepl.needs_confirm({ 'aws s3 cp s3://b/k . --quiet' }), 'download with trailing flag does not ask')

-- cancelling: nothing runs, the line is marked
assert(run('rm -rf /tmp/shrepl-confirm-test'), 'eval asks')
assert(mark_at(0) == '⊘ not run', 'cancelled eval is marked, not run')

-- confirming runs it
answer = 1
assert(run('echo "delete from t" '), 'asks')
assert(vim.wait(5000, function() return mark_at(0) == '=> delete from t' end, 20), 'confirmed eval runs')

-- user patterns: `add` extends, `patterns` replaces, false disables
shrepl.setup({ confirm = { add = { '%f[%w]deploy%.sh' } } })
assert(shrepl.needs_confirm({ './deploy.sh prod' }), 'add extends the list')
assert(shrepl.needs_confirm({ 'rm x' }), 'defaults kept after add')
shrepl.setup({ confirm = { patterns = { '^danger' } } })
assert(not shrepl.needs_confirm({ 'rm x' }) and shrepl.needs_confirm({ 'danger zone' }), 'patterns replaces the list')
shrepl.setup({ confirm = false })
assert(not shrepl.needs_confirm({ 'rm -rf /tmp/x' }), 'confirm = false disables')

print('ok')
vim.cmd('qa!')

param([string]$Output = '', [DateTimeOffset]$At = [DateTimeOffset]::UtcNow)
$ErrorActionPreference = 'Stop'
if (!$Output) { $Output = Join-Path $PSScriptRoot '../data/synthetic.runtime.json' }
if (Test-Path -LiteralPath $Output) { throw 'Refusing to overwrite a dataset. Supply a new output path.' }
$datasetVersion = 'synthetic-0.1.0-' + $At.ToString('yyyyMMddTHHmmssZ')
function Iso($value) { $value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Hash($text) { 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant() }
$records = @()
$sources = @()
foreach ($domain in @('campus-demo','community-demo')) {
    $prefix = if ($domain -eq 'campus-demo') { 'K' } else { 'M' }
    $role = if ($prefix -eq 'K') { 'student' } else { 'resident' }
    $area = if ($prefix -eq 'K') { 'SYN_CAMPUS_A' } else { 'SYN_COMMUNITY_A' }
    $source = 'SRC_SYN_' + $prefix + '_LOCAL'
    $sources += @{sourceId=$source;type='synthetic_authored';domainId=$domain;licenseStatus='pending_team_confirmation';allowedPurpose='local-development-only';realProvider=$false}
    $content = @(
        @{kind='repair';title='合成报修规则';content='公共区域报修维修需填写地点、问题描述和联系代号。先查看草稿并确认，再提交演示工单；无真实受理。'},
        @{kind='notice';title='合成供水维护通知';content='通知：公共区域供水维护，上午九点到十一点暂停供水。请提前准备。'},
        @{kind='service';title='合成办事材料说明';content='居民办事咨询请说明事项；服务台提供材料清单，演示不办理证明、不收身份证。'},
        @{kind='eldercare';title='合成养老服务说明';content='养老服务有公共活动室陪伴与服务台咨询；医疗问题须咨询专业机构，不提供诊断或医疗预约。'},
        @{kind='activity';title='合成活动报名规则';content='活动报名需要选择活动场次和联系代号，先确认草稿；报名截止、名额和重复报名在提交时检查。'},
        @{kind='lost';title='合成失物规则';content='失物拾物发布需物品描述、地点、日期和联系代号，确认后进入待审核，不公开电话或证件。'},
        @{kind='schedule';title='合成课程考试说明';content='课程考试日程仅为演示；个人课表主动导入到客户端本地，不上传教务密码。'}
    )
    foreach ($item in $content) {
        if ($prefix -eq 'K' -and $item.kind -in 'service','eldercare') { continue }
        if ($prefix -eq 'M' -and $item.kind -eq 'schedule') { continue }
        $records += @{evidenceId=($prefix + '_' + $item.kind.ToUpperInvariant());version='1.0.0';sourceId=$source;contentHash=(Hash $item.content);domainId=$domain;roles=@($role,'staff');campus=@($area);publishedAt=(Iso $At);effectiveFrom=(Iso $At.AddDays(-1));effectiveTo=(Iso $At.AddDays(30));kind=$item.kind;matterId=($domain + '.' + $item.kind);title=$item.title;content=$item.content;synthetic=$true;realBusinessWrite=$false;temporalStatus='known_current';revoked=$false}
    }
    foreach ($fixture in @('expired','unknown','staff','other-area')) {
        $item = @{evidenceId=($prefix + '_GUARD_' + $fixture);version='1.0.0';sourceId=$source;contentHash=(Hash '隔离测试秘词：龙舟秘笈');domainId=$domain;roles=@($role);campus=@($area);publishedAt=(Iso $At);effectiveFrom=(Iso $At.AddDays(-3));effectiveTo=(Iso $At.AddDays(30));kind='guard';matterId=($domain + '.guard.' + $fixture);title='隔离测试';content='隔离测试秘词：龙舟秘笈';synthetic=$true;realBusinessWrite=$false;temporalStatus='known_current';revoked=$false}
        if ($fixture -eq 'expired') { $item.effectiveTo = Iso $At.AddDays(-1) }
        if ($fixture -eq 'unknown') { $item.effectiveTo = $null; $item.temporalStatus='unknown' }
        if ($fixture -eq 'staff') { $item.roles = @('staff') }
        if ($fixture -eq 'other-area') { $item.campus = @('SYN_OTHER_AREA') }
        $records += $item
    }
}
$activities = @()
foreach ($domain in @('campus-demo','community-demo')) {
    $activities += @{activityId=($domain + '-activity-001');domainId=$domain;title='合成志愿活动';location='公共活动室';session='morning';startsAt=(Iso $At.AddDays(3));deadlineAt=(Iso $At.AddDays(2));capacity=2;status='OPEN';synthetic=$true}
    $activities += @{activityId=($domain + '-closed');domainId=$domain;title='合成已截止活动';location='公共活动室';session='morning';startsAt=(Iso $At.AddDays(-1));deadlineAt=(Iso $At.AddDays(-2));capacity=1;status='CLOSED';synthetic=$true}
    $activities += @{activityId=($domain + '-full');domainId=$domain;title='合成满额活动';location='公共活动室';session='morning';startsAt=(Iso $At.AddDays(3));deadlineAt=(Iso $At.AddDays(2));capacity=0;status='OPEN';synthetic=$true}
}
$dataset = @{schemaVersion='backend-synthetic-0.1';version=$datasetVersion;generatedAt=(Iso $At);synthetic=$true;realBusinessWrite=$false;provenance='Self-authored local synthetic fixture; no private data or external business source copied';sources=$sources;records=$records;dictionary=@('社区','居民','服务台','公共区域','公共活动室','通知','供水','维护','办事','材料','咨询','物业','维修','报修','地点','描述','联系方式','草稿','确认','工单','养老','医疗','预约','活动','场次','报名','失物','拾物','认领','物品','核验','版本','过期','冲突','权限','校园','课程','考试');activities=$activities;schedule=@(@{scheduleId='course-001';domainId='campus-demo';userId='user-syn-campus-001';kind='course';title='合成仓颉课程';location='教学楼演示教室';startsAt=(Iso $At.AddDays(1));endsAt=(Iso $At.AddDays(1).AddHours(2))},@{scheduleId='exam-001';domainId='campus-demo';userId='user-syn-campus-001';kind='exam';title='合成课程考试';location='教学楼演示教室';startsAt=(Iso $At.AddDays(7));endsAt=(Iso $At.AddDays(7).AddHours(2))});lostItems=@(@{lostItemId='lost-public-001';domainId='campus-demo';kind='lost';itemDescription='合成蓝色水杯';location='图书馆公共区域';occurredOn=$At.ToString('yyyy-MM-dd');status='APPROVED';contactAlias='SYN-CONTACT-K'})}
New-Item -ItemType Directory -Path (Split-Path -Parent $Output) -Force | Out-Null
$dataset | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $Output -Encoding utf8NoBOM
Write-Output ('Generated ' + $Output + ' version=' + $datasetVersion + ' records=' + $records.Count)

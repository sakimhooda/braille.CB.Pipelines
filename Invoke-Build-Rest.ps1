param(
    [Parameter(Mandatory=$true)]
    [string]$packageVersions,
    [Parameter(Mandatory=$true,ValueFromRemainingArguments=$true)]
    [string[]]$pipelines,
    [switch]$fake
)

$warnPrefix = "Warning:"
if ($null -ne $env:SYSTEM_ACCESSTOKEN){
    $oAuthToken = ConvertTo-SecureString -String $env:SYSTEM_ACCESSTOKEN -AsPlainText -Force;
    $authParams = @{
        Authentication = 'OAuth' 
        Token = $oAuthToken
    }
    $warnPrefix = "##vso[task.LogIssue type=warning;]"
}
elseif ($null -ne $env:VSTS_PAT){
    $B64Pat = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(":$env:VSTS_PAT"))
    $authParams = @{
        Headers = @{Authorization=("Basic {0}" -f $B64Pat)}
    }
}

$percentSuccessThreshold = .7;
$minBuilds = 5;
$maxBuilds = 50;
$timeThresholdDays = 3;
$thresholdDate = (Get-Date -AsUTC).AddDays(-$timeThresholdDays);


$definitionUri = "https://microsoft.visualstudio.com/OS/_apis/build/definitions?api-version=6.1-preview.7&definitionIds=$($pipelines | Join-String -Separator ',')&includeLatestBuilds=false"
$definitionResult = Invoke-WebRequest -Method 'GET' -Uri $definitionUri @authParams | ConvertFrom-Json;

$buildsUri = "https://microsoft.visualstudio.com/OS/_apis/build/builds?api-version=6.1-preview.6";
$historyUri = $buildsUri + "&definitions=$($pipelines | Join-String -Separator ',')&status=completed"
$historyResult = Invoke-WebRequest -Method 'GET' -Uri $historyUri @authParams | ConvertFrom-Json;

foreach($pipelineID in $pipelines){
    $recentScheduledFailures = 0;
    $numScheduled = 0;
    $numGeneralFailures = 0;
    $numGeneralSuccess = 0;
    foreach ($build in $historyResult.value | Where-Object {$_.definition.id -eq $pipelineID} ){
        $totalGenericBuilds = $numGeneralFailures + $numGeneralSuccess;
        $queueDate = Get-Date -Date $build.queueTime;
        if ($build.reason -eq "schedule"){
            $numScheduled++;
            if ($build.result -ne "succeeded"){
                $recentScheduledFailures++;
            }
            else{
                break;
            }
        }
        elseif (($queueDate -gt $thresholdDate -and $totalGenericBuilds -lt $maxBuilds) -or ($totalGenericBuilds -lt $minBuilds)){
            if ($build.result -ne "succeeded"){
                $numGeneralFailures++;
            }
            else {
                $numGeneralSuccess++;
            }
        }

    }
    $name = ($definitionResult.value | Where-Object -Property id -EQ $pipelineID | Select-Object -First 1).name;
    $hasScheduled = ($numScheduled -gt 0)

    $body = @{
        definition = @{
            id = $pipelineID
        }
        parameters = @{
            UserSpecifiedPackageVersionOverrideList = $packageVersions
            UserSpecifiedBuildTemplateId = "buildxl_buddy_testing"
        } | ConvertTo-Json -Compress
    };

    if ($null -ne $env:BUILD_QUEUEDBYID){
        $body.requestedFor = @{ id = $env:BUILD_QUEUEDBYID } | ConvertTo-Json -Compress;
    }

    Write-Host `n"$($name):";
    if ($fake -ne $true){
        $queueResult = Invoke-WebRequest -Method 'POST' -Uri $buildsUri @authParams -Body ($body | ConvertTo-Json) -ContentType 'application/json' | ConvertFrom-Json;
        Write-Host `n"$($queueResult._links.web.href)";
    }
    else{
        Write-Host "Body to send for this pipeline: "
        $body | ConvertTo-Json | Write-Host;
    }

    if (!$hasScheduled){
        Write-Host "Pipeline $pipelineID has no scheduled builds.";
        $totalGenericBuilds = $numGeneralFailures + $numGeneralSuccess;
        if ($totalGenericBuilds -gt 0){
            $percentSuccess = $numGeneralSuccess / $totalGenericBuilds;
            $percentInfoString = "{0:P} of the last $totalGenericBuilds completed builds in pipeline $pipelineID have succeeded." -f $percentSuccess;
            if ($percentSuccess -gt $percentSuccessThreshold){
                Write-Host $percentInfoString;
            }
            else {
                Write-Host "$warnPrefix $percentInfoString";
            }
        }
        else {
            Write-Host "$warnPrefix No recent completed builds in pipeline $pipelineID."
        }
    }
    elseif ($recentScheduledFailures -gt 0){
        Write-Host "$warnPrefix The $recentScheduledFailures most recent scheduled builds in pipeline $pipelineID have not succeeded."
    }
    else{
        Write-Host "The latest scheduled build in pipeline $pipelineID succeeded."
    }
}
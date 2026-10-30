param(
    [parameter(Mandatory=$true)]
    [string]$APIToken,
    [ValidateSet('#<TEST_CHANNEL_NAME>','#<PROD_CHANNEL_NAME>')]
    [string]$Channel = "#<TEST_CHANNEL_NAME>", #<TEST_CHANNEL_NAME>
    [string]$Title,
    [parameter(Mandatory=$true, ParameterSetName = 'Text-Only')]
    [parameter(Mandatory=$false, ParameterSetName = 'File')]
    [string]$Text,
    [parameter(ParameterSetName = 'Text-Only')]
    [ValidateSet('good','danger','warning')]
    [string]$Color = 'good',
    [parameter(Mandatory=$true, ParameterSetName = 'File')]
    [string]$FilePath
)
switch ($Channel) {
    '#<PROD_CHANNEL_NAME>' { $ChannelID = "<PROD_CHANNEL_ID>" }
    '#<TEST_CHANNEL_NAME>' { $ChannelID = "<TEST_CHANNEL_ID>" }
    Default {
        $ChannelID = "<TEST_CHANNEL_ID>"
    }
}
if ($PSCmdlet.ParameterSetName -eq 'File') {
    if ( -not (Test-Path $FilePath) ){
        Write-Warning "FilePath ($FilePath) not valid."
        exit 1
    }
    
    $fileName = Split-Path -Path $filePath -Leaf
    $fileLength = (Get-Item $filePath).Length
    if ($FilePath.StartsWith('.\')) {
        $FilePath = (Get-Location).path + "\$fileName"
        Write-Verbose "Converted `$FilePath from relative path to full path ($FilePath)"
    }

    # Request unique URL for file upload
    $getUploadUrlApi = "https://slack.com/api/files.getUploadURLExternal"
    $getUploadUrlParams = @{
        token = $APIToken
        filename = $fileName
        length = $fileLength
    }
    
    # This response should return OK - <fileLength>
    $uploadUrlResponse = Invoke-RestMethod -Uri $getUploadUrlApi -Method Post -Body $getUploadUrlParams

    if ($uploadUrlResponse.ok) {
        $uploadUrl = $uploadUrlResponse.upload_url
        $fileId = $uploadUrlResponse.file_id

        # Upload the file data to the obtained authorized URL
        $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
        $uploadResponse = Invoke-RestMethod -Uri $uploadUrl -Method Post -Body $fileBytes -ContentType 'application/octet-stream'

        Write-Verbose "This is the Upload Response: $uploadResponse"

        if ($uploadResponse -like "*OK*") {
            Write-Output "File upload success"
            $uri = "https://slack.com/api/files.completeUploadExternal"
            $ContentType = "application/json; charset=utf-8"
            
            $body = @{
                files = @(@{
                    id = $fileId
                    title = $Title # message still sends if $Title is null
                })
                channel_id = $channelId
                initial_comment = $Text # message still sends if $text is null
            } | ConvertTo-Json
        } else {
            Write-Warning "Error during file upload: $uploadResponse"
            exit 1
        }
    } else {
        Write-Warning "Error getting upload URL: $($uploadUrlResponse.error)"
        exit 1
    }
}
else {
    $body = @{
        channel = $channelId
        attachments = @(@{
            mrkdwn_in = @('text')
            color = $Color
            title = $Title # message still sends if $Title is null
            text = $text
        })
    } | ConvertTo-Json -Depth 3
    $uri = "https://slack.com/api/chat.postMessage"
    $ContentType = 'application/json;charset=iso-8859-1'
}
$slackBotHeaders = @{
    "Authorization"="Bearer $APIToken"
    "Content-Type" = $ContentType
}
Invoke-RestMethod -Method POST -Uri $uri -Headers $slackBotHeaders -Body $body

### Soli Deo Gloria -mbparis